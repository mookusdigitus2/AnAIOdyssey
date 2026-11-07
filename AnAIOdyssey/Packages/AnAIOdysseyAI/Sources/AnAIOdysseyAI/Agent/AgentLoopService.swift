// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
// Portions adapted from Odysseus v1.0, Copyright (c) 2025 Odysseus Contributors,
// used under the MIT License (see ACKNOWLEDGMENTS.md).
import Foundation
import AnAIOdysseyCore
import AIConnect
import AIModelOptions
import SwiftUI

/// Drives the multi-round, text-based tool-calling agent loop.
///
/// The loop alternates between the model and tool execution: each round it asks
/// the model for a reply, streams the user-visible prose, and parses any fenced
/// tool blocks. If the model called tools, their outputs are fed back as the next
/// "user" turn and another round begins; if it called none, that reply is final.
/// The whole exchange is bounded by `maxRounds` to prevent runaway loops, and the
/// progress is reported as `AgentEvent`s via an `AsyncStream`.
@MainActor
public final class AgentLoopService {
    public let llmService: any LLMServiceProtocol
    /// The tools the agent may call, plus their catalog text for the system prompt.
    public let toolRegistry: AgentToolRegistry
    /// Hard cap on model/tool round-trips, guarding against infinite tool loops.
    public var maxRounds: Int

    public init(
        llmService: any LLMServiceProtocol,
        repositories: RepositoryBundle,
        memoryService: MemoryService,
        calendarAccess: CalendarAgentAccess? = nil,
        extraTools: [any AgentTool] = [],
        extraToolDescriptions: String = "",
        maxRounds: Int = 8
    ) {
        self.llmService = llmService
        self.toolRegistry = .standard(
            repositories: repositories,
            memoryService: memoryService,
            calendarAccess: calendarAccess,
            extraTools: extraTools,
            extraDescriptions: extraToolDescriptions
        )
        self.maxRounds = maxRounds
    }

    public init(
        llmService: any LLMServiceProtocol,
        toolRegistry: AgentToolRegistry,
        maxRounds: Int = 8
    ) {
        self.llmService = llmService
        self.toolRegistry = toolRegistry
        self.maxRounds = maxRounds
    }

    /// How a task run should proceed at the next safe checkpoint.
    public enum RunControl: Sendable, Equatable {
        case proceed
        case pause
        case stop
    }

    /// Public entry point: runs the loop on a background task and surfaces events as an `AsyncStream`.
    public func run(
        prompt: String,
        history: [LLMChatTurn],
        context: AgentContext,
        personaPrompt: String? = nil,
        systemPromptOverride: String? = nil,
        control: @escaping @MainActor () -> RunControl = { .proceed },
        extraStructuredTools: [[String: Any]] = [],
        extraRuntimeTools: [any AgentTool] = [],
        extraSystemNote: String? = nil
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { @MainActor in
                await self.runLoop(
                    prompt: prompt,
                    history: history,
                    context: context,
                    personaPrompt: personaPrompt,
                    systemPromptOverride: systemPromptOverride,
                    control: control,
                    extraStructuredTools: extraStructuredTools,
                    extraRuntimeTools: extraRuntimeTools,
                    extraSystemNote: extraSystemNote,
                    continuation: continuation
                )
            }
        }
    }

    /// The core round-based loop; see the type doc for the overall protocol.
    private func runLoop(
        prompt: String,
        history: [LLMChatTurn],
        context: AgentContext,
        personaPrompt: String?,
        systemPromptOverride: String? = nil,
        control: @escaping @MainActor () -> RunControl = { .proceed },
        extraStructuredTools: [[String: Any]] = [],
        extraRuntimeTools: [any AgentTool] = [],
        extraSystemNote: String? = nil,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        // Guarantee the stream is closed no matter which branch returns.
        defer { continuation.finish() }

        // Lazily load a model on first use; abort the run if it can't load.
        if !llmService.isModelLoaded {
            do {
                try await llmService.loadSelectedModel()
            } catch {
                continuation.yield(.error(message: error.localizedDescription))
                return
            }
        }

        // Seed the rolling conversation from prior user/assistant turns (drop system turns; we add our own).
        var agentContext = context
        var conversation = history.filter { $0.role == "user" || $0.role == "assistant" || $0.role == "tool" }
        var pendingPrompt = prompt
        var pendingFunctionOutputs: [EncodedFunctionCallOutput] = []
        var lastResponseID: String?
        // The parser must recognize *every* registered tool, not just the small
        // hard-coded seed set, or most tool calls would silently go undetected.
        let runtimeTools = Dictionary(uniqueKeysWithValues: extraRuntimeTools.map { ($0.name, $0) })
        var toolTags = toolRegistry.toolNames
        toolTags.formUnion(runtimeTools.keys)
        var structuredTools = AgentToolSchemas.openAITools(for: toolRegistry.toolNames)
        structuredTools.append(contentsOf: extraStructuredTools)
        var collectedCitations: [ChatWebSearchCitation] = []
        var announcedWebSearch = false
        let remoteService: RemoteLLMService? = {
            if let remote = llmService as? RemoteLLMService { return remote }
            if let composite = llmService as? AgentRemoteLLMProviding { return composite.remoteServiceForAgent }
            return nil
        }()

        for round in 0..<maxRounds {
            if Task.isCancelled { return }
            switch control() {
            case .proceed:
                break
            case .pause:
                continuation.yield(.paused(history: conversation, partial: pendingPrompt))
                return
            case .stop:
                continuation.yield(.finished(content: pendingPrompt))
                return
            }

            if pendingFunctionOutputs.isEmpty, !pendingPrompt.isEmpty {
                conversation.append(LLMChatTurn(role: "user", content: pendingPrompt))
                pendingPrompt = ""
            } else if !pendingFunctionOutputs.isEmpty {
                pendingPrompt = ""
            }

            let systemPrompt = appendSystemNote(
                extraSystemNote,
                to: systemPromptOverride
                    ?? agentSystemPrompt(round: round, personaPrompt: personaPrompt)
            )
            var llmHistory = [LLMChatTurn(role: "system", content: systemPrompt)]
            llmHistory.append(contentsOf: conversation)

            var fullResponse = ""
            let responseAdapter = (llmService as? RemoteLLMCapable)?.activeProtocolAdapter
            let visibleGate = VisibleTokenGate(
                tags: toolTags,
                adapter: responseAdapter,
                yield: { continuation.yield(.token($0)) }
            )
            let useRemoteAgent = LocalModelDownloadPolicy.shouldUseRemoteHTTPAgent(
                backendRawValue: (llmService as? any LLMBackendSelectable)?.backendPreference.rawValue ?? "auto",
                activeBackendLabel: (llmService as? any LLMBackendSelectable)?.activeBackendLabel ?? ""
            )
            do {
                if useRemoteAgent, let remoteService {
                    var streamedRaw = ""
                    let roundResult = try await remoteService.agentRound(
                        history: llmHistory,
                        tools: structuredTools,
                        toolNames: toolTags,
                        previousResponseID: lastResponseID,
                        functionCallOutputs: pendingFunctionOutputs,
                        onToken: { piece in
                            streamedRaw += piece
                            visibleGate.emit(from: streamedRaw)
                        },
                        onReasoning: { thought in
                            continuation.yield(.reasoning(thought))
                        },
                        onWebSearch: {
                            if !announcedWebSearch {
                                announcedWebSearch = true
                                continuation.yield(.searchingWeb)
                            }
                        }
                    )
                    if !roundResult.citations.isEmpty {
                        collectedCitations = Self.mergeCitations(collectedCitations, roundResult.citations)
                        continuation.yield(.webSearchCitations(collectedCitations))
                    }
                    fullResponse = roundResult.text
                    lastResponseID = roundResult.responseID
                    pendingFunctionOutputs = []
                    let visibleResponse = AgentStreamingFilter.visibleText(
                        from: responseAdapter?.stripToolBlocks(from: fullResponse, tags: toolTags) ?? fullResponse,
                        tags: toolTags,
                        adapter: responseAdapter
                    )
                    let toolBlocks = roundResult.toolBlocks.isEmpty
                        ? (responseAdapter?.parseToolBlocks(from: fullResponse, tags: toolTags)
                            ?? AgentToolParser.parseToolBlocks(from: fullResponse, tags: toolTags))
                        : roundResult.toolBlocks

                    if toolBlocks.isEmpty {
                        let finalText = visibleResponse.isEmpty ? fullResponse : visibleResponse
                        emitToolFormatHintIfNeeded(
                            toolsWereOffered: !structuredTools.isEmpty,
                            parsedToolCallCount: 0,
                            assistantText: fullResponse,
                            remoteService: remoteService,
                            to: continuation
                        )
                        continuation.yield(.finished(content: finalText))
                        return
                    }

                    let assigned = LLMChatToolHistory.assigningCallIDs(toolBlocks)
                    conversation.append(LLMChatToolHistory.assistantTurn(text: fullResponse, blocks: assigned))
                    let executed = try await executeTools(
                        assigned,
                        context: &agentContext,
                        continuation: continuation,
                        control: control,
                        runtimeTools: runtimeTools,
                        collectedCitations: &collectedCitations
                    )
                    conversation.append(contentsOf: LLMChatToolHistory.toolTurns(outputs: executed.functionOutputs))
                    pendingPrompt = executed.prompt
                    pendingFunctionOutputs = executed.functionOutputs
                    if round == maxRounds - 1 {
                        continuation.yield(.error(message: "Agent reached the maximum number of tool rounds (\(maxRounds))."))
                        continuation.yield(.finished(content: visibleResponse))
                    }
                    continue
                }

                let stream = llmService.streamResponse(to: "", history: llmHistory)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    fullResponse += chunk
                    visibleGate.emit(from: fullResponse)
                }
            } catch is CancellationError {
                return
            } catch {
                continuation.yield(.error(message: error.localizedDescription))
                return
            }

            let toolBlocks = responseAdapter?.parseToolBlocks(from: fullResponse, tags: toolTags)
                ?? AgentToolParser.parseToolBlocks(from: fullResponse, tags: toolTags)
            let visibleResponse = AgentStreamingFilter.visibleText(
                from: responseAdapter?.stripToolBlocks(from: fullResponse, tags: toolTags) ?? fullResponse,
                tags: toolTags,
                adapter: responseAdapter
            )

            if toolBlocks.isEmpty {
                let finalText = visibleResponse.isEmpty ? fullResponse : visibleResponse
                emitCollectedCitations(collectedCitations, to: continuation)
                emitToolFormatHintIfNeeded(
                    toolsWereOffered: !structuredTools.isEmpty,
                    parsedToolCallCount: 0,
                    assistantText: fullResponse,
                    remoteService: remoteService,
                    to: continuation
                )
                continuation.yield(.finished(content: finalText))
                return
            }

            conversation.append(LLMChatTurn(role: "assistant", content: fullResponse))
            do {
                let executed = try await executeTools(
                    toolBlocks,
                    context: &agentContext,
                    continuation: continuation,
                    control: control,
                    runtimeTools: runtimeTools,
                    collectedCitations: &collectedCitations
                )
                pendingPrompt = executed.prompt
                pendingFunctionOutputs = executed.functionOutputs
            } catch {
                continuation.yield(.error(message: error.localizedDescription))
                return
            }

            if round == maxRounds - 1 {
                continuation.yield(.error(message: "Agent reached the maximum number of tool rounds (\(maxRounds))."))
                emitCollectedCitations(collectedCitations, to: continuation)
                continuation.yield(.finished(content: visibleResponse))
                return
            }
        }
    }

    private func executeTools(
        _ toolBlocks: [AgentToolBlock],
        context: inout AgentContext,
        continuation: AsyncStream<AgentEvent>.Continuation,
        control: @escaping @MainActor () -> RunControl = { .proceed },
        runtimeTools: [String: any AgentTool] = [:],
        collectedCitations: inout [ChatWebSearchCitation]
    ) async throws -> (prompt: String, functionOutputs: [EncodedFunctionCallOutput]) {
        var toolResults: [String] = []
        var functionOutputs: [EncodedFunctionCallOutput] = []
        context.shouldContinueTool = { control() == .proceed }
        for block in toolBlocks {
            context.taskProgress?.setCurrentAction(
                AgentTaskRunPolicy.currentAction(forTool: block.toolType)
            )
            if block.toolType == ChatWebSearchPolicy.fallbackToolName {
                continuation.yield(.searchingWeb)
            }
            continuation.yield(.toolStart(name: block.toolType, input: block.content))
            do {
                let result: String
                if let extra = runtimeTools[block.toolType] {
                    result = try await extra.execute(content: block.content, context: &context)
                } else {
                    result = try await toolRegistry.execute(block: block, context: &context)
                }
                if block.toolType == ChatWebSearchPolicy.fallbackToolName {
                    if ChatWebSearchPolicy.isFailedSearchOutput(result) {
                        continuation.yield(.webSearchFailed)
                    } else {
                        if let notice = ChatWebSearchPolicy.parseFallbackNotice(from: result) {
                            continuation.yield(.webSearchNotice(notice))
                        }
                        collectedCitations = Self.mergeCitations(
                            collectedCitations,
                            ChatWebSearchPolicy.parseCitations(from: result)
                        )
                        emitCollectedCitations(collectedCitations, to: continuation)
                    }
                }
                let wrapped = AgentExternalContent.externalToolNames.contains(block.toolType)
                    ? AgentExternalContent.wrap(result)
                    : result
                continuation.yield(.toolResult(name: block.toolType, output: wrapped))
                toolResults.append("[\(block.toolType)]\n\(wrapped)")
                if let callID = block.callID, !callID.isEmpty {
                    functionOutputs.append(EncodedFunctionCallOutput(callID: callID, output: wrapped))
                }
            } catch {
                let message = error.localizedDescription
                continuation.yield(.toolResult(name: block.toolType, output: message))
                toolResults.append("[\(block.toolType) error]\n\(message)")
                if let callID = block.callID, !callID.isEmpty {
                    functionOutputs.append(EncodedFunctionCallOutput(callID: callID, output: message))
                }
            }
        }
        return (toolResults.joined(separator: "\n\n"), functionOutputs)
    }

    private func appendSystemNote(_ note: String?, to prompt: String) -> String {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return prompt
        }
        return prompt + "\n\n" + note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitToolFormatHintIfNeeded(
        toolsWereOffered: Bool,
        parsedToolCallCount: Int,
        assistantText: String,
        remoteService: RemoteLLMService?,
        to continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        let modelID = remoteService?.selectedModelID ?? ""
        let encoding = remoteService?.activeProtocolAdapter?.encoding
        let forcedHarmony = encoding == .lmStudioHarmony && !ToolFormatFallbackPolicy.looksLikeGPTOSS(modelID)
        guard ToolFormatFallbackPolicy.shouldSuggestDifferentFormat(
            toolsWereOffered: toolsWereOffered,
            parsedToolCallCount: parsedToolCallCount,
            assistantText: assistantText,
            forcedHarmonyOnNonGPTOSS: forcedHarmony
        ) else { return }
        continuation.yield(.toolFormatHint(
            model: modelID,
            connectionID: remoteService?.activeConnectionID
        ))
    }

    private func emitCollectedCitations(
        _ citations: [ChatWebSearchCitation],
        to continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        guard !citations.isEmpty else { return }
        continuation.yield(.webSearchCitations(citations))
    }

    private static func mergeCitations(
        _ existing: [ChatWebSearchCitation],
        _ incoming: [ChatWebSearchCitation]
    ) -> [ChatWebSearchCitation] {
        var seen = Set(existing.map(\.url))
        var merged = existing
        for citation in incoming where seen.insert(citation.url).inserted {
            merged.append(citation)
        }
        return merged
    }

    /// Builds the per-round system prompt: tool catalog, usage rules, and (after round 0) a continuation nudge.
    private func agentSystemPrompt(round: Int, personaPrompt: String?) -> String {
        var prompt = ""
        if let personaPrompt {
            let trimmed = personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                prompt += trimmed
                prompt += "\n\n"
            }
        }
        prompt += """
        You are an AI assistant with tool access inside \(AppBranding.appName).
        To use a tool, write a fenced code block with the tool name as the language tag,
        or call the matching native function when available.
        The block executes automatically and you see the output.

        \(AgentExternalContent.systemRule)

        \(toolRegistry.toolDescriptions)

        ## Rules
        - You have read access to everything stored in \(AppBranding.appName): documents, notes, chats, tasks, research, calendar, gallery, comparisons, and memories.
        - Email and calendar are private and permission-gated: the email tools and the list_calendar_events / create_calendar_event tools only work if the user enabled them in Settings → AI Data Access. If a tool reports access is disabled, tell the user to enable it there rather than retrying. The calendar tools also need system Calendar permission (iOS Settings → \(AppBranding.appName) → Calendars) and, for Google Calendar, a connected Gmail account.
        - You don't know today's date from training. Call current_date whenever a request depends on the date or time (today, tomorrow, "next Friday", due dates, event times).
        - Use create_calendar_event to add calendar items the user asks for (meetings, reminders with a date, appointments).
        - You can draft emails (new, reply, reply-all, or forward) with draft_email. Drafts are saved to the Email tab for the user to review and send via Gmail. You cannot send mail directly — the user sends from the Email tab. For a reply/forward, read the original with read_email first (requires email access), then draft.
        - Use list_* tools first when you need to discover ids; then read_* tools for full content.
        - Use create_note, create_document, or create_task to persist new content the user asks for.
        - save_memory is for long-term facts about the user; create_note is for user-visible notes.
        - Only use tools when needed.
        - After a tool succeeds, reply briefly unless more work remains.
        - After a tool fails, retry with a fix or explain what is blocking you.
        - For small document edits, always use edit_document with FIND/REPLACE blocks.
        """
        // After the first round, remind the model to build on the tool results it just received.
        if round > 0 {
            prompt += "\n- Continue from the latest tool results."
        }
        return prompt
    }
}

/// Turns a growing visible snapshot into incremental `.token` slices.
private final class VisibleTokenGate {
    private var tokens = StreamTextAccumulator()
    private let tags: Set<String>
    private let adapter: RemoteLLMProtocolAdapter?
    private let yield: (String) -> Void

    init(tags: Set<String>, adapter: RemoteLLMProtocolAdapter?, yield: @escaping (String) -> Void) {
        self.tags = tags
        self.adapter = adapter
        self.yield = yield
    }

    func emit(from raw: String) {
        let visible = AgentStreamingFilter.visibleText(
            from: raw,
            tags: tags,
            adapter: adapter
        )
        let increment = tokens.apply(.snapshot(visible))
        if !increment.isEmpty {
            yield(increment)
        }
    }
}

/// Environment key making the active `AgentLoopService` reachable from SwiftUI views.
private struct AgentLoopServiceKey: EnvironmentKey {
    static let defaultValue: AgentLoopService? = nil
}

public extension EnvironmentValues {
    /// The agent loop service available to the current view tree.
    var agentLoopService: AgentLoopService? {
        get { self[AgentLoopServiceKey.self] }
        set { self[AgentLoopServiceKey.self] = newValue }
    }
}

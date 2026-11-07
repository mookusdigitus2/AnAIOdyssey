// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Wraps the in-app `LLMServiceProtocol` as a tagged agent adapter.
@MainActor
public final class LLMAgentAdapter: AgentAdapter {
    public let attributes: AgentAttributes
    private let llmService: any LLMServiceProtocol

    public init(
        id: String,
        displayName: String,
        vendor: String,
        tags: [String],
        llmService: any LLMServiceProtocol,
        isSwitchable: Bool = true
    ) {
        self.attributes = AgentAttributes(
            id: id,
            displayName: displayName,
            vendor: vendor,
            tags: tags,
            capabilities: ["chat", "completion", "tools"],
            isSwitchable: isSwitchable
        )
        self.llmService = llmService
    }

    public var isAvailable: Bool {
        llmService.isModelLoaded || !llmService.selectedModelID.isEmpty
    }

    public func run(assignment: AgentAssignment) async throws -> AgentRunResult {
        var parts: [String] = []
        if let context = assignment.context?.combinedText {
            parts.append("Context:\n\(context)")
        }
        if let prompt = assignment.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        let message = parts.isEmpty ? "Continue." : parts.joined(separator: "\n\n")
        if !llmService.isModelLoaded {
            try await llmService.loadSelectedModel()
        }
        let output = try await llmService.completeResponse(to: message)
        return AgentRunResult(output: output, metadata: ["model": llmService.selectedModelID])
    }
}

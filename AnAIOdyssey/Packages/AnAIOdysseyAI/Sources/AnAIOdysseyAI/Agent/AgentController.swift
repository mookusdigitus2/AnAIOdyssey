// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// Multi-agent orchestrator: queue, auto-run, and pause/continue/stop.
@MainActor
public final class AgentController: ObservableObject, AgentResearchRunning, AgentDocumentWriting {
    public let registry: AgentAdapterRegistry
    public let settings: AgentRegistrySettings
    private let repositories: RepositoryBundle
    private let appSupportDirectory: URL
    private let llmService: (any LLMServiceProtocol)?
    private let memoryService: MemoryService?
    private let featureModelSettings: FeatureModelSettings?
    private let providerSettings: ProviderSettings?
    private let researchService: ResearchService?
    private let documentWritingService: DocumentWritingService?

    private var jobs: [String: Task<Void, Never>] = [:]
    private var pauseRequested: Set<String> = []
    private var stopRequested: Set<String> = []

    public init(
        registry: AgentAdapterRegistry,
        settings: AgentRegistrySettings,
        repositories: RepositoryBundle,
        appSupportDirectory: URL,
        llmService: (any LLMServiceProtocol)? = nil,
        memoryService: MemoryService? = nil,
        featureModelSettings: FeatureModelSettings? = nil,
        providerSettings: ProviderSettings? = nil,
        researchService: ResearchService? = nil,
        documentWritingService: DocumentWritingService? = nil
    ) {
        self.registry = registry
        self.settings = settings
        self.repositories = repositories
        self.appSupportDirectory = appSupportDirectory
        self.llmService = llmService
        self.memoryService = memoryService
        self.featureModelSettings = featureModelSettings
        self.providerSettings = providerSettings
        self.researchService = researchService
        self.documentWritingService = documentWritingService
    }

    public var controllerAdapter: (any AgentAdapter)? {
        registry.adapter(id: settings.resolvedControllerID)
    }

    /// Creates a task and starts it immediately.
    @discardableResult
    public func enqueue(
        title: String,
        assignment: String,
        assigneeAgentID: String? = nil,
        contextInline: String? = nil,
        contextFileText: String? = nil,
        parentTaskID: String? = nil,
        sessionID: String? = nil,
        priority: Int = 0,
        autoStart: Bool = true
    ) throws -> AgentTask {
        var fileName: String?
        if let contextFileText, !contextFileText.isEmpty {
            let taskID = UUID().uuidString
            fileName = try AgentTaskContextStore.save(
                text: contextFileText,
                appSupport: appSupportDirectory,
                taskID: taskID
            )
        }
        let task = try repositories.agentTasks.createTask(
            title: title,
            assignment: assignment,
            controllerAgentID: settings.resolvedControllerID,
            assigneeAgentID: nil,
            contextInline: contextInline,
            contextFileName: fileName,
            parentTaskID: parentTaskID,
            sessionID: sessionID,
            priority: priority
        )
        try repositories.agentTasks.updateTask(
            id: task.id,
            title: nil,
            assignment: nil,
            status: AgentTaskStatus.paused.rawValue,
            assigneeAgentID: nil,
            handoffTarget: nil,
            contextInline: nil,
            contextFileName: nil,
            resultSummary: nil
        )
        try repositories.agentTaskEvents.appendEvent(
            taskID: task.id,
            actorType: "system",
            actorID: settings.resolvedControllerID,
            action: "created",
            message: "Task created"
        )
        if autoStart {
            startRun(taskID: task.id, resume: false)
        }
        return try repositories.agentTasks.fetchTask(id: task.id) ?? task
    }

    /// Pause in-flight work after a process restart. Safer than auto-resuming
    /// HTTP/tool rounds with a half-rebuilt conversation.
    public func recoverInterruptedRuns() {
        let tasks = (try? repositories.agentTasks.listAllTasks(status: nil)) ?? []
        for task in tasks {
            let migrated = AgentTaskStatus.migrateStored(task.status)
            let recovered = AgentTaskStatus.afterLaunchRecovery(migrated)
            if recovered.rawValue != task.status {
                try? repositories.agentTasks.updateTask(
                    id: task.id,
                    title: nil,
                    assignment: nil,
                    status: recovered.rawValue,
                    assigneeAgentID: nil,
                    handoffTarget: nil,
                    contextInline: nil,
                    contextFileName: nil,
                    resultSummary: nil
                )
                if let live = try? repositories.agentTasks.fetchTask(id: task.id) {
                    live.currentAction = nil
                    try? repositories.agentTasks.save()
                }
            }
        }
        objectWillChange.send()
    }

    public func pause(taskID: String) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        let status = AgentTaskStatus.migrateStored(task.status)
        guard AgentTaskRunPolicy.apply(.pause, to: map(status)) == .paused else { return }
        pauseRequested.insert(taskID)
        if jobs[taskID] == nil {
            applyStatus(taskID: taskID, status: .paused, action: nil)
        }
    }

    public func continueRun(taskID: String) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        let status = AgentTaskStatus.migrateStored(task.status)
        guard AgentTaskRunPolicy.apply(.continueRun, to: map(status)) == .running else { return }
        pauseRequested.remove(taskID)
        stopRequested.remove(taskID)
        startRun(taskID: taskID, resume: true)
    }

    public func stop(taskID: String) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        let status = AgentTaskStatus.migrateStored(task.status)
        guard AgentTaskRunPolicy.apply(.stop, to: map(status)) == .stopped else { return }
        stopRequested.insert(taskID)
        pauseRequested.remove(taskID)
        if let job = jobs[taskID] {
            job.cancel()
        } else {
            applyStatus(taskID: taskID, status: .stopped, action: nil)
        }
    }

    public func startRun(taskID: String, resume: Bool) {
        jobs[taskID]?.cancel()
        pauseRequested.remove(taskID)
        stopRequested.remove(taskID)
        applyStatus(taskID: taskID, status: .running, action: resume ? "continuing" : "starting")
        jobs[taskID] = Task { [weak self] in
            await self?.runLoop(taskID: taskID, resume: resume)
        }
    }

    public func listQueueTasks(status: String? = nil) throws -> [AgentTask] {
        try repositories.agentTasks.listTasks(status: status)
    }

    public func history(for taskID: String) throws -> [AgentTaskEvent] {
        try repositories.agentTaskEvents.listEvents(taskID: taskID)
    }

    public func artifacts(for taskID: String) throws -> [AgentArtifact] {
        try repositories.agentArtifacts.listArtifacts(taskID: taskID)
    }

    public func updateTaskStatus(taskID: String, status: AgentTaskStatus) throws {
        try repositories.agentTasks.updateTask(
            id: taskID,
            title: nil,
            assignment: nil,
            status: status.rawValue,
            assigneeAgentID: nil,
            handoffTarget: nil,
            contextInline: nil,
            contextFileName: nil,
            resultSummary: nil
        )
        try repositories.agentTaskEvents.appendEvent(
            taskID: taskID,
            actorType: "human",
            actorID: "user",
            action: "status_changed",
            message: "Status set to \(status.displayName)"
        )
        objectWillChange.send()
    }

    public func deleteTask(id: String) throws {
        jobs[id]?.cancel()
        jobs[id] = nil
        pauseRequested.remove(id)
        stopRequested.remove(id)
        let subtasks = try repositories.agentTasks.listSubtasks(parentTaskID: id)
        for subtask in subtasks {
            try deleteTask(id: subtask.id)
        }
        if let task = try repositories.agentTasks.fetchTask(id: id),
           let fileName = task.contextFileName {
            AgentTaskContextStore.delete(fileName: fileName, appSupport: appSupportDirectory)
        }
        let artifacts = try repositories.agentArtifacts.listArtifacts(taskID: id)
        for artifact in artifacts {
            try repositories.agentArtifacts.deleteArtifact(id: artifact.id)
        }
        try repositories.agentTaskEvents.deleteEvents(taskID: id)
        try repositories.agentTasks.deleteTask(id: id)
        objectWillChange.send()
    }

    @discardableResult
    public func createArtifact(
        taskID: String,
        kind: AgentArtifactKind,
        title: String,
        body: String,
        linkedEntityID: String? = nil
    ) throws -> AgentArtifact {
        let artifact = try repositories.agentArtifacts.createArtifact(
            taskID: taskID,
            kind: kind.rawValue,
            title: title,
            body: body,
            linkedEntityID: linkedEntityID
        )
        try repositories.agentTaskEvents.appendEvent(
            taskID: taskID,
            actorType: "system",
            actorID: nil,
            action: "artifact_created",
            message: "\(kind.displayName): \(title)"
        )
        return artifact
    }

    private func runLoop(taskID: String, resume: Bool) async {
        defer {
            jobs[taskID] = nil
            objectWillChange.send()
        }
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID),
              let llmService,
              let memoryService
        else {
            applyStatus(
                taskID: taskID,
                status: .error,
                action: nil,
                error: "Task runner is not configured."
            )
            return
        }

        applyFeatureModel(.tasks, to: llmService)

        let registry = AgentToolRegistry.taskWorkspace(repositories: repositories)
        let loop = AgentLoopService(llmService: llmService, toolRegistry: registry)
        let sink = TaskProgressRecorder(controller: self, taskID: taskID)
        var context = AgentContext(
            sessionID: task.sessionID ?? task.id,
            repositories: repositories,
            memoryService: memoryService,
            taskProgress: sink,
            researchRunner: self,
            documentWriter: self
        )

        var history = decodeConversation(task.conversationJSON)
        let prompt: String
        if resume, !history.isEmpty {
            prompt = "Continue the assignment from where you paused. Do not repeat finished work."
        } else {
            prompt = buildPrompt(for: task)
            history = []
        }

        var systemPrompt = """
        You are completing an agent task inside \(AppBranding.appName).
        \(AgentTaskRunPolicy.boundarySentence)
        Use only the listed document and research tools. Never invent email or calendar access.
        If the assignment asks you to research, look up, or investigate a topic, call run_research so the Research feature does that work. Do not write a research report with document tools.
        If the assignment asks you to write, draft, or create a document, call write_document so the Documents writing feature does that work. Do not compose the full document yourself.
        A task may do both: run_research first, then write_document using the research as context.

        \(registry.toolDescriptions)
        """
        if AgentTaskRunPolicy.shouldUseResearchFeature(task.assignment) {
            systemPrompt += "\n\nThis assignment includes research. You must call run_research."
        }
        if AgentTaskRunPolicy.shouldUseDocumentsFeature(task.assignment) {
            systemPrompt += "\n\nThis assignment includes writing a document. You must call write_document."
        }

        var collected = task.resultSummary ?? ""
        for await event in loop.run(
            prompt: prompt,
            history: history,
            context: context,
            systemPromptOverride: systemPrompt,
            control: { [weak self] in
                guard let self else { return .stop }
                if self.stopRequested.contains(taskID) { return .stop }
                if self.pauseRequested.contains(taskID) { return .pause }
                return .proceed
            }
        ) {
            switch event {
            case .token(let text):
                collected += text
                persistResult(taskID: taskID, summary: collected)
            case .toolStart(let name, _):
                setAction(taskID: taskID, AgentTaskRunPolicy.currentAction(forTool: name))
            case .toolResult, .searchingWeb, .webSearchCitations, .webSearchFailed, .webSearchNotice, .reasoning, .toolFormatHint:
                break
            case .paused(let saved, let partial):
                persistConversation(taskID: taskID, history: saved)
                if !partial.isEmpty {
                    persistResult(taskID: taskID, summary: collected + partial)
                }
                applyStatus(taskID: taskID, status: .paused, action: nil)
                try? repositories.agentTaskEvents.appendEvent(
                    taskID: taskID,
                    actorType: "human",
                    actorID: "user",
                    action: "paused",
                    message: "Paused"
                )
                return
            case .finished(let content):
                if stopRequested.contains(taskID) {
                    persistResult(taskID: taskID, summary: collected.isEmpty ? content : collected)
                    persistConversation(taskID: taskID, history: [])
                    applyStatus(taskID: taskID, status: .stopped, action: nil)
                    try? repositories.agentTaskEvents.appendEvent(
                        taskID: taskID,
                        actorType: "human",
                        actorID: "user",
                        action: "stopped",
                        message: "Stopped; kept work so far."
                    )
                    return
                }
                persistResult(taskID: taskID, summary: content.isEmpty ? collected : content)
                persistConversation(taskID: taskID, history: [])
                applyStatus(taskID: taskID, status: .done, action: nil)
                try? repositories.agentTaskEvents.appendEvent(
                    taskID: taskID,
                    actorType: "ai",
                    actorID: settings.resolvedControllerID,
                    action: "completed",
                    message: AgentTaskEventSummary.message(for: content.isEmpty ? collected : content)
                )
                return
            case .error(let message):
                persistResult(taskID: taskID, summary: collected)
                applyStatus(taskID: taskID, status: .error, action: nil, error: message)
                try? repositories.agentTaskEvents.appendEvent(
                    taskID: taskID,
                    actorType: "ai",
                    actorID: settings.resolvedControllerID,
                    action: "failed",
                    message: message
                )
                return
            }
        }

        if stopRequested.contains(taskID) {
            applyStatus(taskID: taskID, status: .stopped, action: nil)
        } else if pauseRequested.contains(taskID) {
            applyStatus(taskID: taskID, status: .paused, action: nil)
        }
    }

    private func buildPrompt(for task: AgentTask) -> String {
        var parts: [String] = ["Assignment:\n\(task.assignment)"]
        if let inline = task.contextInline, !inline.isEmpty {
            parts.append("Context:\n\(inline)")
        }
        if let fileName = task.contextFileName,
           let fileText = try? AgentTaskContextStore.load(
                fileName: fileName,
                appSupport: appSupportDirectory
           ),
           !fileText.isEmpty {
            parts.append("Attached context:\n\(fileText)")
        }
        return parts.joined(separator: "\n\n")
    }

    public func runResearch(
        query: String,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> AgentResearchRunResult {
        guard let researchService, let providerSettings else {
            throw ResearchServiceError.generationFailed("Research is not configured.")
        }
        let configuration = featureConfiguration(for: .research)
        let report = try await researchService.runResearchToReport(
            query: query,
            configuration: configuration,
            shouldContinue: shouldContinue
        )
        if let llmService {
            applyFeatureModel(.tasks, to: llmService)
        }
        return AgentResearchRunResult(
            id: report.id,
            title: report.query,
            summary: report.summary
        )
    }

    public func writeDocument(
        title: String?,
        brief: String,
        existingDocumentID: String?,
        extraContext: String?,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> AgentDocumentWriteResult {
        guard let documentWritingService else {
            throw DocumentWritingError.notConfigured
        }
        let configuration = featureConfiguration(for: .documents)
        let result = try await documentWritingService.writeDocument(
            title: title,
            brief: brief,
            existingDocumentID: existingDocumentID,
            extraContext: extraContext,
            configuration: configuration,
            shouldContinue: shouldContinue
        )
        if let llmService {
            applyFeatureModel(.tasks, to: llmService)
        }
        return AgentDocumentWriteResult(
            id: result.id,
            title: result.title,
            excerpt: result.excerpt,
            created: result.created
        )
    }

    private func featureConfiguration(for feature: WorkspaceFeature) -> ResearchRunConfiguration {
        guard let featureModelSettings, let providerSettings else {
            return LLMModelPreparer.defaultResearchConfiguration(
                providerSettings: providerSettings ?? ProviderSettings()
            )
        }
        let key = featureModelSettings.resolvedSelectionKey(
            for: feature,
            providerSettings: providerSettings,
            agentSettings: settings
        )
        if let parsed = ConfiguredModelRegistry.parseSelectionKey(key) {
            return ResearchRunConfiguration(
                modelID: parsed.modelID,
                backend: parsed.backend == .localMLX ? .auto : parsed.backend,
                connectionID: parsed.connectionID
            )
        }
        return LLMModelPreparer.defaultResearchConfiguration(providerSettings: providerSettings)
    }

    private func applyFeatureModel(_ feature: WorkspaceFeature, to llmService: any LLMServiceProtocol) {
        guard let featureModelSettings, let providerSettings else { return }
        let key = featureModelSettings.resolvedSelectionKey(
            for: feature,
            providerSettings: providerSettings,
            agentSettings: settings
        )
        AgentLLMDefaults.apply(
            selectionKey: key,
            to: llmService,
            providerSettings: providerSettings
        )
    }

    fileprivate func applyStatus(
        taskID: String,
        status: AgentTaskStatus,
        action: String?,
        error: String? = nil
    ) {
        try? repositories.agentTasks.updateTask(
            id: taskID,
            title: nil,
            assignment: nil,
            status: status.rawValue,
            assigneeAgentID: nil,
            handoffTarget: nil,
            contextInline: nil,
            contextFileName: nil,
            resultSummary: nil
        )
        if let task = try? repositories.agentTasks.fetchTask(id: taskID) {
            task.currentAction = action
            task.errorMessage = error
            task.updatedAt = .now
            try? repositories.agentTasks.save()
        }
        objectWillChange.send()
    }

    fileprivate func setAction(taskID: String, _ action: String) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        task.currentAction = action
        task.updatedAt = .now
        try? repositories.agentTasks.save()
        objectWillChange.send()
    }

    fileprivate func recordChange(
        taskID: String,
        action: String,
        kind: String,
        itemID: String,
        title: String
    ) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        let entry = AgentTaskChangeEntry(action: action, kind: kind, itemID: itemID, title: title)
        task.changeLogJSON = AgentTaskRunPolicy.appendChange(entry, to: task.changeLogJSON)
        task.currentAction = AgentTaskRunPolicy.currentAction(action: action, title: title)
        task.updatedAt = .now
        try? repositories.agentTasks.save()
        try? repositories.agentTaskEvents.appendEvent(
            taskID: taskID,
            actorType: "ai",
            actorID: settings.resolvedControllerID,
            action: action,
            message: entry.label
        )
        objectWillChange.send()
    }

    private func persistResult(taskID: String, summary: String) {
        try? repositories.agentTasks.updateTask(
            id: taskID,
            title: nil,
            assignment: nil,
            status: nil,
            assigneeAgentID: nil,
            handoffTarget: nil,
            contextInline: nil,
            contextFileName: nil,
            resultSummary: summary
        )
    }

    private func persistConversation(taskID: String, history: [LLMChatTurn]) {
        guard let task = try? repositories.agentTasks.fetchTask(id: taskID) else { return }
        if history.isEmpty {
            task.conversationJSON = nil
        } else if let data = try? JSONEncoder().encode(history),
                  let text = String(data: data, encoding: .utf8) {
            task.conversationJSON = text
        }
        try? repositories.agentTasks.save()
    }

    private func decodeConversation(_ json: String?) -> [LLMChatTurn] {
        guard let json, let data = json.data(using: .utf8),
              let turns = try? JSONDecoder().decode([LLMChatTurn].self, from: data)
        else {
            return []
        }
        return turns
    }

    private func map(_ status: AgentTaskStatus) -> AgentTaskRunStatus {
        AgentTaskRunStatus(rawValue: status.rawValue) ?? .paused
    }
}

@MainActor
private final class TaskProgressRecorder: AgentTaskProgressSink {
    private let controller: AgentController
    private let taskID: String

    init(controller: AgentController, taskID: String) {
        self.controller = controller
        self.taskID = taskID
    }

    func setCurrentAction(_ text: String) {
        controller.setAction(taskID: taskID, text)
    }

    func recordChange(action: String, kind: String, itemID: String, title: String) {
        controller.recordChange(
            taskID: taskID,
            action: action,
            kind: kind,
            itemID: itemID,
            title: title
        )
    }
}

private enum AgentTaskEventSummary {
    static func message(for output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 500 else { return trimmed }
        return String(trimmed.prefix(500)) + "… (\(trimmed.count) characters — see Result for full text)"
    }
}

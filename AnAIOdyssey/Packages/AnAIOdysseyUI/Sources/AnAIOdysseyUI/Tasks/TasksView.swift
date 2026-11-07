// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import Combine
import SwiftUI

/// Tasks workspace: scheduled reminders + multi-agent central queue.
public struct TasksView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case scheduled
        case agentQueue = "agent"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scheduled: return "Scheduled"
            case .agentQueue: return "Agent Queue"
            }
        }
    }

    @Environment(\.repositories) private var repositories
    @Environment(\.taskSchedulerService) private var taskScheduler
    @Environment(\.agentController) private var agentController
    @EnvironmentObject private var agentSettings: AgentRegistrySettings

    @State private var mode: Mode = .scheduled

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Agent tasks are hidden in TestFlight/App Store builds
            // (AgentTaskVisibilityPolicy); only Scheduled shows there.
            if AgentTaskVisibilityPolicy.isAgentQueueVisible {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
            }

            switch AgentTaskVisibilityPolicy.isAgentQueueVisible ? mode : .scheduled {
            case .scheduled:
                ScheduledTasksPanel()
            case .agentQueue:
                AgentQueuePanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Tasks")
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PopOutWindowButton(windowID: AppWindowID.tasks)
            }
        }
        #endif
        .accessibilityIdentifier("tasks-view")
    }
}

// MARK: - Scheduled tasks

private struct ScheduledTasksPanel: View {
    @Environment(\.repositories) private var repositories
    @Environment(\.taskSchedulerService) private var taskScheduler
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var tasks: [ScheduledTask] = []
    @State private var selectedTaskID: String?
    @State private var showingNew = false
    @State private var errorMessage: String?
    // Snapshotted from the view-body environment because custom environment keys
    // do not reliably propagate into nested-navigation toolbar content.
    @State private var schedulerAvailable = false

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            phoneBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            taskList
        } detail: {
            if let task = selectedTask {
                ScheduledTaskDetail(
                    task: task,
                    onChanged: reload,
                    onDeleted: {
                        selectedTaskID = nil
                        reload()
                    }
                )
            } else {
                ContentUnavailableView("Select a Task", systemImage: "checklist")
            }
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
        .sheet(isPresented: $showingNew) {
            NewScheduledTaskSheet(onCreate: { name, prompt, schedule, time, date in
                createTask(name: name, prompt: prompt, schedule: schedule, time: time, date: date)
            })
        }
        .onAppear(perform: reload)
        .overlay { errorOverlay }
    }

    #if os(iOS)
    private var phoneBody: some View {
        NavigationStack {
            Group {
                if let task = selectedTask {
                    ScheduledTaskDetail(
                        task: task,
                        onChanged: reload,
                        onDeleted: {
                            selectedTaskID = nil
                            reload()
                        }
                    )
                } else {
                    taskList
                }
            }
            .navigationTitle(selectedTask?.name ?? "Scheduled Tasks")
            .navigationBarTitleDisplayMode(selectedTask == nil ? .inline : .inline)
            .toolbar { phoneToolbar }
        }
        .sheet(isPresented: $showingNew) {
            NewScheduledTaskSheet(onCreate: { name, prompt, schedule, time, date in
                createTask(name: name, prompt: prompt, schedule: schedule, time: time, date: date)
            })
        }
        .onAppear(perform: reload)
        .overlay { errorOverlay }
    }
    #endif

    private var taskList: some View {
        Group {
            if usesPhoneTaskList {
                List {
                    scheduledTaskRows(useSelection: false)
                }
            } else {
                List(selection: $selectedTaskID) {
                    scheduledTaskRows(useSelection: true)
                }
            }
        }
        .macWorkspaceSplit()
        .toolbar { scheduledToolbar }
    }

    @ToolbarContentBuilder
    private var scheduledToolbar: some ToolbarContent {
        if !usesPhoneTaskList {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .disabled(!schedulerAvailable)
                .accessibilityIdentifier("new-scheduled-task-button")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: reload) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .workspaceActionButtonTint()
            }
        }
    }

    @ViewBuilder
    private func scheduledTaskRows(useSelection: Bool) -> some View {
        if tasks.isEmpty {
            WorkspaceEmptyListLabel(text: "No scheduled tasks")
        } else {
            ForEach(tasks, id: \.id) { task in
                if useSelection {
                    ScheduledTaskRow(task: task)
                        .tag(task.id)
                } else {
                    Button {
                        selectedTaskID = task.id
                    } label: {
                        ScheduledTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete(perform: deleteAt)
        }
    }

    private var usesPhoneTaskList: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var phoneToolbar: some ToolbarContent {
        if selectedTask != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    selectedTaskID = nil
                } label: {
                    Label("Tasks", systemImage: "chevron.left")
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingNew = true } label: {
                Label("New Task", systemImage: "plus")
            }
            .workspaceActionButtonTint()
            .disabled(!schedulerAvailable)
            .accessibilityIdentifier("new-scheduled-task-button")

            Button(action: reload) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .workspaceActionButtonTint()
        }
    }
    #endif

    @ViewBuilder
    private var errorOverlay: some View {
        if let errorMessage {
            VStack {
                StatusMessage(kind: .error, text: errorMessage)
                Spacer()
            }
            .padding()
        }
    }

    private var selectedTask: ScheduledTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    private func reload() {
        schedulerAvailable = taskScheduler != nil
        guard let repositories else { return }
        let fetched = (try? repositories.tasks.listTasks(status: nil)) ?? []
        tasks = Self.sortedScheduledTasks(fetched)
    }

    private static func sortedScheduledTasks(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        tasks.sorted { lhs, rhs in
            let lhsDone = lhs.status == TaskStatus.completed.rawValue
            let rhsDone = rhs.status == TaskStatus.completed.rawValue
            if lhsDone != rhsDone { return !lhsDone }
            switch (lhs.nextRun, rhs.nextRun) {
            case let (l?, r?):
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private func createTask(name: String, prompt: String?, schedule: String?, time: String?, date: Date?) {
        guard let taskScheduler else { return }
        Task {
            do {
                let sched = TaskSchedule(rawValue: schedule ?? TaskSchedule.daily.rawValue) ?? .daily
                _ = try await taskScheduler.createTask(
                    name: name,
                    prompt: prompt,
                    schedule: sched,
                    scheduledTime: time,
                    scheduledDate: date
                )
                await MainActor.run {
                    showingNew = false
                    reload()
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func deleteAt(_ offsets: IndexSet) {
        guard let taskScheduler else { return }
        for index in offsets {
            try? taskScheduler.deleteTask(id: tasks[index].id)
        }
        reload()
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                if let next = task.nextRun {
                    Text(next, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        switch task.status {
        case TaskStatus.active.rawValue: return .green
        case TaskStatus.paused.rawValue: return .orange
        case TaskStatus.completed.rawValue: return .secondary
        default: return .secondary
        }
    }
}

private struct ScheduledTaskDetail: View {
    let task: ScheduledTask
    let onChanged: () -> Void
    let onDeleted: () -> Void
    @Environment(\.taskSchedulerService) private var taskScheduler
    @Environment(\.repositories) private var repositories
    @State private var showingDeleteConfirm = false
    @State private var selectedStatus: String

    init(task: ScheduledTask, onChanged: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.task = task
        self.onChanged = onChanged
        self.onDeleted = onDeleted
        _selectedStatus = State(initialValue: task.status)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: task.name)
                Picker("Status", selection: $selectedStatus) {
                    ForEach([TaskStatus.active, .paused, .completed], id: \.rawValue) { status in
                        Text(status.rawValue.capitalized).tag(status.rawValue)
                    }
                }
                .onChange(of: selectedStatus) { _, newValue in
                    guard newValue != task.status else { return }
                    applyStatus(newValue)
                }
                if let prompt = task.prompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        PlainMessageContentView(content: prompt)
                    }
                }
                if let next = task.nextRun {
                    LabeledContent("Next Run", value: next.formatted(date: .abbreviated, time: .shortened))
                }
                if let last = task.lastRun {
                    LabeledContent("Last Run", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                if task.status == TaskStatus.active.rawValue {
                    Button("Pause") { togglePause() }
                } else if task.status == TaskStatus.paused.rawValue {
                    Button("Resume") { toggleResume() }
                } else if task.status == TaskStatus.completed.rawValue {
                    Button("Reactivate") { reactivate() }
                }
                Button("Delete Task", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
        }
        .navigationTitle(task.name)
        .onChange(of: task.status) { _, newValue in
            selectedStatus = newValue
        }
        .destructiveDeleteAlert(
            "Delete “\(task.name)”?",
            isPresented: $showingDeleteConfirm,
            message: "This removes the task and cancels any pending reminders.",
            confirmAction: deleteTask
        )
    }

    private func deleteTask() {
        guard let taskScheduler else { return }
        try? taskScheduler.deleteTask(id: task.id)
        onDeleted()
    }

    private func togglePause() {
        Task {
            try? await taskScheduler?.pauseTask(id: task.id)
            onChanged()
        }
    }

    private func toggleResume() {
        Task {
            try? await taskScheduler?.resumeTask(id: task.id)
            onChanged()
        }
    }

    private func reactivate() {
        Task {
            try? await taskScheduler?.reactivateTask(id: task.id)
            onChanged()
        }
    }

    private func applyStatus(_ status: String) {
        guard let taskScheduler else { return }
        Task {
            switch status {
            case TaskStatus.active.rawValue:
                try? await taskScheduler.reactivateTask(id: task.id)
            case TaskStatus.paused.rawValue:
                try? await taskScheduler.pauseTask(id: task.id)
            case TaskStatus.completed.rawValue:
                try? await taskScheduler.completeTask(id: task.id)
            default:
                break
            }
            await MainActor.run { onChanged() }
        }
    }
}

private struct NewScheduledTaskSheet: View {
    let onCreate: (String, String?, String?, String?, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = TaskSchedule.daily.rawValue
    @State private var time = "09:00"
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(2...4)
                Picker("Schedule", selection: $schedule) {
                    ForEach(TaskSchedule.allCases, id: \.rawValue) { s in
                        Text(s.rawValue.capitalized).tag(s.rawValue)
                    }
                }
                TextField("Time (HH:mm)", text: $time)
                if schedule == TaskSchedule.once.rawValue {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("New Scheduled Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(
                            name,
                            prompt.isEmpty ? nil : prompt,
                            schedule,
                            time,
                            schedule == TaskSchedule.once.rawValue ? date : nil
                        )
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

// MARK: - Agent queue

private struct AgentQueuePanel: View {
    @Environment(\.agentController) private var agentController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var tasks: [AgentTask] = []
    @State private var selectedTaskID: String?
    @State private var showingNew = false
    @State private var errorMessage: String?
    @State private var controllerAvailable = false

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            phoneBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            queueList
        } detail: {
            if let task = selectedTask {
                AgentTaskDetailView(
                    taskID: task.id,
                    onChanged: reload,
                    onDeleted: {
                        selectedTaskID = nil
                        reload()
                    }
                )
            } else {
                ContentUnavailableView(
                    "Agent Tasks",
                    systemImage: "checklist",
                    description: Text(AgentTaskRunPolicy.boundarySentence)
                )
            }
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
        .sheet(isPresented: $showingNew) {
            NewAgentTaskSheet(onCreate: enqueue)
        }
        .onAppear(perform: reload)
        .onReceive(agentControllerChange) { _ in reload() }
        .overlay { errorOverlay }
    }

    #if os(iOS)
    private var phoneBody: some View {
        NavigationStack {
            Group {
                if let task = selectedTask {
                    AgentTaskDetailView(
                        taskID: task.id,
                        onChanged: reload,
                        onDeleted: {
                            selectedTaskID = nil
                            reload()
                        }
                    )
                } else {
                    queueList
                }
            }
            .navigationTitle(selectedTask?.title ?? "Agent Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { phoneToolbar }
        }
        .sheet(isPresented: $showingNew) {
            NewAgentTaskSheet(onCreate: enqueue)
        }
        .onAppear(perform: reload)
        .onReceive(agentControllerChange) { _ in reload() }
        .overlay { errorOverlay }
    }
    #endif

    private var queueList: some View {
        Group {
            if usesPhoneTaskList {
                List {
                    agentTaskRows(useSelection: false)
                }
            } else {
                List(selection: $selectedTaskID) {
                    agentTaskRows(useSelection: true)
                }
            }
        }
        .macWorkspaceSplit()
        .toolbar { agentQueueToolbar }
    }

    @ToolbarContentBuilder
    private var agentQueueToolbar: some ToolbarContent {
        if !usesPhoneTaskList {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .workspaceActionButtonTint()
                .disabled(!controllerAvailable)
                .accessibilityIdentifier("new-agent-task-button")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: reload) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .workspaceActionButtonTint()
            }
        }
    }

    @ViewBuilder
    private func agentTaskRows(useSelection: Bool) -> some View {
        if tasks.isEmpty {
            WorkspaceEmptyListLabel(text: "No agent tasks")
        } else {
            ForEach(tasks, id: \.id) { task in
                if useSelection {
                    AgentTaskRow(task: task)
                        .tag(task.id)
                } else {
                    Button {
                        selectedTaskID = task.id
                    } label: {
                        AgentTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete(perform: deleteAt)
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var phoneToolbar: some ToolbarContent {
        if selectedTask != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    selectedTaskID = nil
                } label: {
                    Label("Tasks", systemImage: "chevron.left")
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingNew = true } label: {
                Label("New Task", systemImage: "plus")
            }
            .workspaceActionButtonTint()
            .disabled(!controllerAvailable)
            .accessibilityIdentifier("new-agent-task-button")

            Button(action: reload) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
        }
    }
    #endif

    @ViewBuilder
    private var errorOverlay: some View {
        if let errorMessage {
            VStack {
                StatusMessage(kind: .error, text: errorMessage)
                Spacer()
            }
            .padding()
        }
    }

    private var usesPhoneTaskList: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var selectedTask: AgentTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    private var agentControllerChange: ObservableObjectPublisher {
        agentController?.objectWillChange ?? ObservableObjectPublisher()
    }

    private func reload() {
        controllerAvailable = agentController != nil
        guard let agentController else { return }
        let fetched = (try? agentController.listQueueTasks()) ?? []
        tasks = Self.sortedAgentTasks(fetched)
    }

    private static func sortedAgentTasks(_ tasks: [AgentTask]) -> [AgentTask] {
        let terminal: Set<String> = [
            AgentTaskStatus.done.rawValue,
            AgentTaskStatus.stopped.rawValue,
            AgentTaskStatus.error.rawValue,
        ]
        return tasks.sorted { lhs, rhs in
            let lhsTerminal = terminal.contains(AgentTaskStatus.migrateStored(lhs.status).rawValue)
            let rhsTerminal = terminal.contains(AgentTaskStatus.migrateStored(rhs.status).rawValue)
            if lhsTerminal != rhsTerminal { return !lhsTerminal }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func enqueue(title: String, assignment: String, context: String?) {
        guard let agentController else { return }
        do {
            let task = try agentController.enqueue(
                title: title,
                assignment: assignment,
                contextInline: context,
                contextFileText: (context?.count ?? 0) > 4000 ? context : nil
            )
            showingNew = false
            selectedTaskID = task.id
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAt(_ offsets: IndexSet) {
        guard let agentController else { return }
        for index in offsets {
            let id = tasks[index].id
            try? agentController.deleteTask(id: id)
        }
        if let selectedTaskID, offsets.contains(where: { tasks[$0].id == selectedTaskID }) {
            self.selectedTaskID = nil
        }
        reload()
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.body)
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusLine: String {
        let status = AgentTaskStatus.migrateStored(task.status)
        let run = AgentTaskRunStatus(rawValue: status.rawValue) ?? .paused
        return AgentTaskRunPolicy.statusLine(
            status: run,
            currentAction: task.currentAction,
            errorMessage: task.errorMessage
        )
    }
}

private struct AgentTaskDetailView: View {
    let taskID: String
    let onChanged: () -> Void
    let onDeleted: () -> Void
    @Environment(\.agentController) private var agentController
    @State private var task: AgentTask?
    @State private var events: [AgentTaskEvent] = []
    @State private var artifacts: [AgentArtifact] = []
    @State private var showingDeleteConfirm = false

    var body: some View {
        Group {
            if let task {
                taskForm(task)
            } else {
                ContentUnavailableView("Task Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .onAppear(perform: reloadDetails)
        .onChange(of: taskID) { _, _ in reloadDetails() }
        .onReceive(agentController?.objectWillChange ?? ObservableObjectPublisher()) { _ in
            reloadDetails()
        }
    }

    @ViewBuilder
    private func taskForm(_ task: AgentTask) -> some View {
        let status = AgentTaskStatus.migrateStored(task.status)
        let run = AgentTaskRunStatus(rawValue: status.rawValue) ?? .paused
        Form {
            Section {
                Text(
                    AgentTaskRunPolicy.statusLine(
                        status: run,
                        currentAction: task.currentAction,
                        errorMessage: task.errorMessage
                    )
                )
                .font(.body.weight(.medium))
                .accessibilityIdentifier("agent-task-status-line")

                let changes = AgentTaskRunPolicy.decodeChangeLog(task.changeLogJSON)
                if !changes.isEmpty {
                    ForEach(changes) { entry in
                        Button(entry.label) {
                            if entry.kind == "research" {
                                WorkspaceOpenRequest.post(kind: .research, itemID: entry.itemID)
                            } else {
                                WorkspaceOpenRequest.post(kind: .document, itemID: entry.itemID)
                            }
                        }
                        .isolatedFormButton()
                        .accessibilityIdentifier("agent-task-change-\(entry.itemID)")
                    }
                }
            }

            Section {
                HStack(spacing: 16) {
                    if AgentTaskRunPolicy.canPauseOrContinue(run) {
                        Button {
                            togglePauseContinue(status)
                        } label: {
                            Image(systemName: status == .running ? "pause.fill" : "play.fill")
                        }
                        .isolatedFormButton()
                        .accessibilityLabel(status == .running ? "Pause" : "Continue")
                        .accessibilityIdentifier("agent-task-pause-continue")
                    }
                    if AgentTaskRunPolicy.canStop(run) {
                        Button {
                            agentController?.stop(taskID: taskID)
                            reloadDetails()
                            onChanged()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .isolatedFormButton()
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("agent-task-stop")
                    }
                }
                Text(AgentTaskRunPolicy.boundarySentence)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .accessibilityIdentifier("agent-task-boundary")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PlainMessageContentView(content: task.assignment)
                }
                if let summary = task.resultSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Result")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollableTextDocumentView(
                            text: summary,
                            maxContentHeight: nil
                        )
                    }
                }
            }

            Section("History") {
                if events.isEmpty {
                    Text("No events yet").foregroundStyle(.secondary)
                } else {
                    ForEach(events, id: \.id) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.action).font(.caption.weight(.semibold))
                            PlainMessageContentView(content: event.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.createdAt, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if !artifacts.isEmpty {
                Section("Artifacts") {
                    ForEach(artifacts, id: \.id) { artifact in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(artifact.title).font(.headline)
                            ScrollableTextDocumentView(
                                text: artifact.body,
                                maxContentHeight: nil
                            )
                        }
                    }
                }
            }

            Section {
                Button("Delete Task", role: .destructive) {
                    showingDeleteConfirm = true
                }
                .isolatedFormButton()
            }
        }
        .navigationTitle(task.title)
        .destructiveDeleteAlert(
            "Delete “\(task.title)”?",
            isPresented: $showingDeleteConfirm,
            message: "This permanently removes the task and its history.",
            confirmAction: deleteTask
        )
    }

    private func deleteTask() {
        try? agentController?.deleteTask(id: taskID)
        onDeleted()
    }

    private func togglePauseContinue(_ status: AgentTaskStatus) {
        if status == .running {
            agentController?.pause(taskID: taskID)
        } else {
            agentController?.continueRun(taskID: taskID)
        }
        reloadDetails()
        onChanged()
    }

    private func reloadDetails() {
        guard let agentController else { return }
        task = (try? agentController.listQueueTasks())?.first { $0.id == taskID }
        events = (try? agentController.history(for: taskID)) ?? []
        artifacts = (try? agentController.artifacts(for: taskID)) ?? []
    }
}

private struct NewAgentTaskSheet: View {
    let onCreate: (String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var assignment = ""
    @State private var context = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Assignment / prompt", text: $assignment, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Context (optional)", text: $context, axis: .vertical)
                    .lineLimit(2...8)
            }
            .navigationTitle("New Agent Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onCreate(title, assignment, context.isEmpty ? nil : context)
                    }
                    .disabled(title.isEmpty || assignment.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 360)
    }
}

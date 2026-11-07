// SPDX-License-Identifier: MIT
import Combine
import Foundation

/// Where a run's model executes. On-device (MLX / Apple Foundation) work can't
/// use the GPU once the app is in the background, so it is stopped cleanly;
/// cloud runs keep going under a background-task assertion.
public enum RunExecution: Equatable, Sendable {
    case cloud
    case onDevice
}

public enum RunStopReason: Equatable, Sendable {
    /// The user tapped Stop.
    case user
    /// iOS took the app's background time away, or the run was on-device.
    case leftApp

    public var message: String {
        switch self {
        case .user: "Stopped"
        case .leftApp: "Stopped when you left the app"
        }
    }
}

public enum RunPhase: Equatable, Sendable {
    case running
    case finished
    case stopped(RunStopReason)
    case failed(String)
}

/// Observable state of one run, readable by any view (rows, tab dot, banner).
public struct RunSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var execution: RunExecution
    public var phase: RunPhase
    /// Partial output so far; kept when a run stops so it's never lost.
    public var text: String
    /// Live status line ("Using …", "Running search…").
    public var status: String?

    public var isRunning: Bool { phase == .running }

    /// A run that stopped or failed partway can be resumed (re-run).
    public var canResume: Bool {
        switch phase {
        case .stopped, .failed: true
        default: false
        }
    }

    /// Text to show on the row instead of presenting partial output as complete.
    public var statusMessage: String? {
        switch phase {
        case .stopped(let reason): reason.message
        case .failed(let message): message
        default: nil
        }
    }
}

/// Begins/ends an OS background-task assertion (UIApplication on iOS).
@MainActor
public protocol BackgroundTaskAsserting: AnyObject {
    func begin(name: String, expiration: @escaping () -> Void) -> Int
    func end(_ token: Int)
}

/// Handed to a run's work closure to publish progress into the center.
@MainActor
public final class RunHandle {
    let id: String
    let generation: Int
    weak var center: BackgroundRunCenter?

    init(id: String, generation: Int, center: BackgroundRunCenter) {
        self.id = id
        self.generation = generation
        self.center = center
    }

    /// Replaces the run's visible partial text.
    public func update(text: String) {
        center?.apply(id: id, generation: generation) { $0.text = text }
    }

    /// Sets the run's status line.
    public func update(status: String?) {
        center?.apply(id: id, generation: generation) { $0.status = status }
    }

    /// True once this run was stopped or replaced; work should stop persisting.
    public var isCurrent: Bool {
        center?.isCurrent(id: id, generation: generation) ?? false
    }
}

/// App-level owner of long-running Chat / Research work, so a run is tied to
/// the app's lifetime instead of the view that started it. Leaving the tab,
/// closing a sheet or popping a chat no longer loses the run; on iOS 17-25 the
/// app gets ~30 s of background time, after which cloud runs are marked
/// stopped (never shown as complete) and can be resumed.
@MainActor
public final class BackgroundRunCenter: ObservableObject {
    public typealias Work = @MainActor (RunHandle) async throws -> Void

    /// One center per feature.
    public static let research = BackgroundRunCenter()
    public static let chat = BackgroundRunCenter()
    /// Ids a visible view is showing; no banner is needed for those.
    public var watchedIDs: Set<String> = []

    @Published public private(set) var runs: [String: RunSnapshot] = [:]

    /// Called once when a run finishes, stops or fails (banner / notification).
    public var onRunEnded: ((RunSnapshot) -> Void)?
    public var backgroundAssertion: BackgroundTaskAsserting?
    public private(set) var isInBackground = false

    private var tasks: [String: Task<Void, Never>] = [:]
    private var handles: [String: RunHandle] = [:]
    private var works: [String: Work] = [:]
    private var generations: [String: Int] = [:]
    private var assertionToken: Int?

    public init() {}

    public func snapshot(for id: String) -> RunSnapshot? { runs[id] }
    /// Handle of the current run, for code that publishes progress without
    /// having been handed it (nil once the run ended).
    public func currentHandle(id: String) -> RunHandle? {
        guard let handle = handles[id], isCurrent(id: id, generation: handle.generation) else { return nil }
        return handle
    }
    public func isRunning(id: String) -> Bool { runs[id]?.isRunning == true }
    public var activeRunCount: Int { runs.values.filter(\.isRunning).count }
    public var activeRuns: [RunSnapshot] { runs.values.filter(\.isRunning).sorted { $0.id < $1.id } }

    public func start(id: String, title: String, execution: RunExecution, work: @escaping Work) {
        cancelTask(id: id)
        works[id] = work
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        runs[id] = RunSnapshot(id: id, title: title, execution: execution, phase: .running, text: "", status: nil)
        let handle = RunHandle(id: id, generation: generation, center: self)
        handles[id] = handle
        tasks[id] = Task { @MainActor [weak self] in
            do {
                try await work(handle)
                try Task.checkCancellation()
                self?.end(id: id, generation: generation, phase: .finished)
            } catch is CancellationError {
                // Stop/background already set the phase.
            } catch {
                if Task.isCancelled { return }
                self?.end(id: id, generation: generation, phase: .failed(error.localizedDescription))
            }
        }
        if isInBackground { syncAssertion() }
    }

    /// User-initiated Stop. Partial text stays.
    public func stop(id: String) {
        stop(id: id, reason: .user)
    }

    /// Re-runs a stopped or failed run with its original work.
    public func resume(id: String) {
        guard let snap = runs[id], snap.canResume, let work = works[id] else { return }
        start(id: id, title: snap.title, execution: snap.execution, work: work)
    }

    /// Forgets an ended run (after its result was shown).
    public func dismiss(id: String) {
        guard runs[id]?.isRunning != true else { return }
        runs[id] = nil
        works[id] = nil
    }

    // MARK: Scene phase

    public func sceneDidEnterBackground() {
        isInBackground = true
        // GPU work is killed in the background: stop on-device runs first.
        for snap in runs.values where snap.isRunning && snap.execution == .onDevice {
            stop(id: snap.id, reason: .leftApp)
        }
        syncAssertion()
    }

    public func sceneWillEnterForeground() {
        isInBackground = false
        releaseAssertion()
    }

    // MARK: Internals

    func isCurrent(id: String, generation: Int) -> Bool {
        generations[id] == generation && runs[id]?.isRunning == true
    }

    func apply(id: String, generation: Int, _ change: (inout RunSnapshot) -> Void) {
        guard isCurrent(id: id, generation: generation), var snap = runs[id] else { return }
        change(&snap)
        runs[id] = snap
    }

    private func stop(id: String, reason: RunStopReason) {
        guard runs[id]?.isRunning == true else { return }
        cancelTask(id: id)
        if var snap = runs[id] {
            snap.phase = .stopped(reason)
            snap.status = nil
            runs[id] = snap
            onRunEnded?(snap)
        }
        syncAssertion()
    }

    private func end(id: String, generation: Int, phase: RunPhase) {
        guard isCurrent(id: id, generation: generation), var snap = runs[id] else { return }
        snap.phase = phase
        snap.status = nil
        runs[id] = snap
        tasks[id] = nil
        onRunEnded?(snap)
        syncAssertion()
    }

    private func cancelTask(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    /// Holds a background assertion only while backgrounded with cloud runs.
    private func syncAssertion() {
        let needs = isInBackground && runs.values.contains { $0.isRunning && $0.execution == .cloud }
        if needs, assertionToken == nil, let backgroundAssertion {
            assertionToken = backgroundAssertion.begin(name: "AnAIOdyssey.runs") { [weak self] in
                self?.backgroundTimeExpired()
            }
        } else if !needs {
            releaseAssertion()
        }
    }

    private func backgroundTimeExpired() {
        for snap in runs.values where snap.isRunning {
            stop(id: snap.id, reason: .leftApp)
        }
        releaseAssertion()
    }

    private func releaseAssertion() {
        if let token = assertionToken {
            assertionToken = nil
            backgroundAssertion?.end(token)
        }
    }
}

/// App-level center for Research runs (new queries and follow-ups).
public enum ResearchRunCenter {
    @MainActor public static var shared: BackgroundRunCenter { .research }
}

/// App-level center for Chat generations, keyed by chat session id.
public enum ChatGenerationCenter {
    @MainActor public static var shared: BackgroundRunCenter { .chat }
}

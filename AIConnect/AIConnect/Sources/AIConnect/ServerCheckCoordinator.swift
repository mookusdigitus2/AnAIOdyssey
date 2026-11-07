// SPDX-License-Identifier: MIT
import Foundation

/// Asks local servers what they are (LM Studio, Ollama, or another OpenAI-style server) without
/// holding anything up for long: all servers at once at launch, and before a send only the
/// connection being used, for at most a couple of seconds. A check that runs past that keeps
/// going and saves its answer for the next request.
@MainActor
public final class ServerCheckCoordinator {
    private let settings: ProviderSettings
    private let session: URLSession?
    private var running: [String: Task<Void, Never>] = [:]

    public init(settings: ProviderSettings, session: URLSession? = nil) {
        self.settings = settings
        self.session = session
    }

    /// True when this connection's server should be asked before a request: an enabled local
    /// or LM Studio–style server with no answer for its current URL. Never for cloud rows, and
    /// nil (an on-device model) never needs one.
    public func needsCheck(connectionID: String?) -> Bool {
        guard let connectionID, let connection = settings.connection(id: connectionID) else { return false }
        return connection.isEnabled && connection.mayServeLMStudio && !connection.detectionIsCurrent
    }

    /// Starts a check of every server that needs one, in parallel. Doesn't wait.
    public func startLaunchChecks() {
        for connection in settings.remoteConnections where needsCheck(connectionID: connection.id) {
            start(connection.id)
        }
    }

    /// Before a send: checks the connection's server if it has no answer yet (including one that
    /// was off at launch), waiting at most `seconds`.
    public func checkBeforeSend(connectionID: String?, waitingAtMost seconds: TimeInterval = 2.5) async {
        guard let connectionID, needsCheck(connectionID: connectionID) else { return }
        await Self.wait(for: start(connectionID), atMost: seconds)
    }

    @discardableResult
    private func start(_ connectionID: String) -> Task<Void, Never> {
        if let task = running[connectionID] { return task }
        let service = RemoteLLMService(settings: settings, session: session)
        let task = Task { [weak self] in
            await service.detectServer(for: connectionID)
            self?.running[connectionID] = nil
        }
        running[connectionID] = task
        return task
    }

    private static func wait(for task: Task<Void, Never>, atMost seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate(continuation)
            Task { await task.value; gate.open() }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.open()
            }
        }
    }
}

/// Resumes a continuation once, from whichever side finishes first.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func open() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

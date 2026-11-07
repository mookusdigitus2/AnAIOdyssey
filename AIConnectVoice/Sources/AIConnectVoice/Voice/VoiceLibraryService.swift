// SPDX-License-Identifier: MIT
import AIModelOptions
import AIConnect
import Foundation

/// Events the add-voice UI renders. The view never runs the work itself.
public enum VoiceAddEvent: Equatable, Sendable {
    case idle
    case lookingUp
    case found(ElevenLabsVoiceRecord, isLibrary: Bool)
    case notFound
    case adding
    case added(ElevenLabsVoiceRecord)
    case failed(String)
}

public protocol VoiceAddBackend: Sendable {
    func lookup(apiKey: String, voiceID: String) async throws -> ElevenLabsVoiceLookup
    func addShared(apiKey: String, publicOwnerID: String, voiceID: String, name: String) async throws
}

public struct ElevenLabsVoiceAddBackend: VoiceAddBackend {
    public init() {}
    public func lookup(apiKey: String, voiceID: String) async throws -> ElevenLabsVoiceLookup {
        try await ElevenLabsVoiceService.lookupVoice(apiKey: apiKey, voiceID: voiceID)
    }
    public func addShared(apiKey: String, publicOwnerID: String, voiceID: String, name: String) async throws {
        try await ElevenLabsVoiceService.addSharedVoice(apiKey: apiKey, publicOwnerID: publicOwnerID, voiceID: voiceID, name: name)
    }
}

/// Runs ElevenLabs voice lookup/add off the UI. Owned outside any view
/// (`shared`), so dismissing the picker only ends its event subscription:
/// an in-flight add still finishes and persists, and nothing writes into a
/// dismissed view.
public actor VoiceLibraryService {
    public static let shared = VoiceLibraryService(
        backend: ProcessInfo.processInfo.environment["UITEST_SLOW_VOICE_LOOKUP"] != nil
            ? UITestSlowLookupBackend() : ElevenLabsVoiceAddBackend(),
        banners: .shared
    )

    public static let lookupTimeoutMessage = "Lookup timed out. Check your connection and the voice ID, then try again."

    private let backend: VoiceAddBackend
    private let lookupDebounce: Duration
    private let lookupTimeout: Duration
    private var subscribers: [UUID: AsyncStream<VoiceAddEvent>.Continuation] = [:]
    private var lookupTask: Task<Void, Never>?
    private var latestLookupSequence = Int.min
    private var addTasks: [String: Task<Void, Never>] = [:]
    private var inFlight = VoiceAddInFlight()
    private let banners: VoiceLibraryBannerCenter?
    public private(set) var lastEvent: VoiceAddEvent = .idle

    public init(backend: VoiceAddBackend, lookupDebounce: Duration = .milliseconds(400),
                lookupTimeout: Duration = .seconds(8),
                banners: VoiceLibraryBannerCenter? = nil) {
        self.backend = backend
        self.lookupDebounce = lookupDebounce
        self.lookupTimeout = lookupTimeout
        self.banners = banners
    }

    /// Subscribe; the stream replays the latest event. Cancelling the
    /// consuming task (view dismissed) removes the subscriber.
    public func events() -> AsyncStream<VoiceAddEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<VoiceAddEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(lastEvent)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    public var subscriberCount: Int { subscribers.count }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func emit(_ event: VoiceAddEvent) {
        lastEvent = event
        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Intent: the voice ID text changed.
    /// `sequence` orders keystrokes: each keystroke hops to this actor in its
    /// own Task, and those can arrive out of order. Without it a late short
    /// prefix ("21m00T") cancelled the full ID's lookup and reset to idle, so
    /// "Looking up…" never showed and Save stayed disabled.
    public func lookup(voiceID raw: String, apiKey: String, sequence: Int? = nil) {
        if let sequence {
            guard sequence > latestLookupSequence else { return }
            latestLookupSequence = sequence
        }
        lookupTask?.cancel()
        let voiceID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard voiceID.count >= 12 else { emit(.idle); return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { emit(.failed("ElevenLabs API key is not configured.")); return }
        emit(.lookingUp)
        let debounce = lookupDebounce
        let timeout = lookupTimeout
        let backend = backend
        lookupTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let event: VoiceAddEvent
            do {
                let result = try await withThrowingTaskGroup(of: ElevenLabsVoiceLookup?.self) { group in
                    group.addTask { try await backend.lookup(apiKey: key, voiceID: voiceID) }
                    group.addTask { try await Task.sleep(for: timeout); return nil }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
                guard let result else {
                    event = .failed(Self.lookupTimeoutMessage)
                    guard !Task.isCancelled else { return }
                    self.finishLookup(event)
                    return
                }
                switch result {
                case .account(let r): event = .found(r, isLibrary: false)
                case .library(let r): event = .found(r, isLibrary: true)
                case .notFound: event = .notFound
                }
            } catch {
                event = .failed((error as? LocalizedError)?.errorDescription ?? ElevenLabsVoiceErrors.listFailedMessage)
            }
            guard !Task.isCancelled else { return }
            self.finishLookup(event)
        }
    }

    private func finishLookup(_ event: VoiceAddEvent) { emit(event) }

    /// Intent: Save. Library voices persist only after ElevenLabs accepts the add.
    /// `persist` runs on the main actor against settings that outlive the view.
    /// Returns false (and does nothing) when an add for this voice ID is already
    /// in flight, so Save + Retry can't create duplicates.
    @discardableResult
    public func add(_ record: ElevenLabsVoiceRecord, isLibrary: Bool, apiKey: String,
                    persist: @escaping @MainActor @Sendable (ElevenLabsVoiceRecord) -> Void) -> Bool {
        guard inFlight.begin(record.voiceID) else { return false }
        lookupTask?.cancel()
        emit(.adding)
        let backend = backend
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        addTasks[record.voiceID] = Task {
            var failure: String?
            if isLibrary, let owner = record.publicOwnerID {
                if key.isEmpty {
                    failure = "ElevenLabs API key is not configured."
                } else {
                    do {
                        try await backend.addShared(apiKey: key, publicOwnerID: owner, voiceID: record.voiceID, name: record.name)
                    } catch {
                        failure = (error as? LocalizedError)?.errorDescription
                            ?? ElevenLabsVoiceErrors.userFacingTTSMessage(error.localizedDescription)
                    }
                }
            }
            if failure == nil { await persist(record) }
            await self.finishAdd(record, failure: failure, isLibrary: isLibrary, apiKey: key, persist: persist)
        }
        return true
    }

    private func finishAdd(_ record: ElevenLabsVoiceRecord, failure: String?, isLibrary: Bool, apiKey: String,
                           persist: @escaping @MainActor @Sendable (ElevenLabsVoiceRecord) -> Void) async {
        addTasks[record.voiceID] = nil
        inFlight.end(record.voiceID)
        emit(failure.map(VoiceAddEvent.failed) ?? .added(record))
        guard let banners else { return }
        let state: VoiceLibraryBannerState = failure.map {
            .failed(voiceID: record.voiceID, name: record.name, message: $0)
        } ?? .added(voiceID: record.voiceID, name: record.name)
        await banners.show(state) { [weak self] in
            Task { await self?.add(record, isLibrary: isLibrary, apiKey: apiKey, persist: persist) }
        }
    }

    public func isInFlight(_ voiceID: String) -> Bool { inFlight.contains(voiceID) }

    /// Back/Done/Cancel: drop the uncommitted lookup only. Adds the user
    /// already saved keep running so ElevenLabs never ends up half-added.
    public func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        if case .lookingUp = lastEvent { emit(.idle) }
    }

    /// Intent: Cancel. Drops a pending lookup; an add already sent is left to finish.
    public func reset() {
        lookupTask?.cancel()
        if addTasks.isEmpty { emit(.idle) }
    }

    /// Test hook.
    public func waitForAdds() async {
        for task in addTasks.values { await task.value }
    }
}

/// App-wide banner for finished voice adds. The root view renders it, so the
/// user sees the result wherever they are.
@MainActor
public final class VoiceLibraryBannerCenter: ObservableObject {
    nonisolated public static let shared = VoiceLibraryBannerCenter()
    @Published public private(set) var banner: VoiceLibraryBannerState?
    private var retryAction: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    nonisolated public init() {}

    public func show(_ state: VoiceLibraryBannerState, retry: @escaping () -> Void) {
        banner = state
        retryAction = state.showsRetry ? retry : nil
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(state.isProblem ? 8 : 4))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    public func retry() {
        let action = retryAction
        dismiss()
        action?()
    }

    public func dismiss() {
        dismissTask?.cancel()
        banner = nil
        retryAction = nil
    }
}

/// UI-test backend (launch env UITEST_SLOW_VOICE_LOOKUP): lookups never
/// return within the test, so Cancel/Back can be exercised mid-lookup.
struct UITestSlowLookupBackend: VoiceAddBackend {
    func lookup(apiKey: String, voiceID: String) async throws -> ElevenLabsVoiceLookup {
        try await Task.sleep(for: .seconds(60))
        return .notFound
    }
    func addShared(apiKey: String, publicOwnerID: String, voiceID: String, name: String) async throws {}
}

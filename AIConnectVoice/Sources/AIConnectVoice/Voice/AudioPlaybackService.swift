// SPDX-License-Identifier: MIT
import AVFoundation
import AIConnect
import Foundation

/// Plays MP3/other audio data sequentially through the shared duplex engine.
@MainActor
final class AudioPlaybackService {
    private var queue: [Data] = []
    private var isDraining = false
    private var drainContinuations: [CheckedContinuation<Void, Error>] = []
    private var queueError: Error?

    func play(data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.append(data)
            self.drainContinuations.append(continuation)
            self.pumpQueue()
        }
    }

    func enqueue(data: Data) {
        guard !data.isEmpty else { return }
        queue.append(data)
        pumpQueue()
    }

    func waitUntilFinished() async throws {
        if queue.isEmpty && !isDraining && !VoiceDuplexEngine.shared.isPlayingBack {
            if let queueError {
                let error = queueError
                self.queueError = nil
                throw error
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.drainContinuations.append(continuation)
            self.pumpQueue()
        }
    }

    func stop() {
        queue.removeAll()
        isDraining = false
        queueError = nil
        VoiceDuplexEngine.shared.stopPlayback()
        finishAllWaiters(with: .success(()))
    }

    private func pumpQueue() {
        guard !isDraining else { return }
        guard let next = queue.first else {
            guard !drainContinuations.isEmpty else { return }
            Task { await self.finishWhenEngineDrains() }
            return
        }
        queue.removeFirst()
        isDraining = true
        VoiceDuplexEngine.shared.scheduleCompressed(data: next)
        Task { await self.finishCurrentClip() }
    }

    private func finishCurrentClip() async {
        await VoiceDuplexEngine.shared.waitUntilFinished()
        isDraining = false
        if queue.isEmpty {
            await finishWhenEngineDrains()
        } else {
            pumpQueue()
        }
    }

    private func finishWhenEngineDrains() async {
        await VoiceDuplexEngine.shared.waitUntilFinished()
        let result: Result<Void, Error>
        if let queueError {
            result = .failure(queueError)
            self.queueError = nil
        } else {
            result = .success(())
        }
        finishAllWaiters(with: result)
    }

    private func finishAllWaiters(with result: Result<Void, Error>) {
        let waiters = drainContinuations
        drainContinuations.removeAll()
        for waiter in waiters {
            switch result {
            case .success:
                waiter.resume()
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
    }
}

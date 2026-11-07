// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Coalesces bursts of updates into one action after a quiet interval — the
/// shared debounced-autosave primitive (replaces per-view cancel/sleep tasks).
@MainActor
final class Debouncer {
    private var pending: Task<Void, Never>?
    private let interval: Duration

    init(interval: Duration = .milliseconds(400)) {
        self.interval = interval
    }

    /// Schedules `action`, cancelling any previously scheduled one so only the
    /// last call within the quiet interval runs.
    func schedule(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

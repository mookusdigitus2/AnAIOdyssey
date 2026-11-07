// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import AIModelOptions

/// Download/availability status of a single on-device model, for the management UI.
///
/// Combines the static catalog metadata (`option`) with live, on-disk facts:
/// whether the weights are present, how much space they occupy, and whether the
/// model is even permitted to run under the device's ¾-RAM budget.
public struct LocalModelStatus: Identifiable, Sendable, Hashable {
    /// The catalog entry this status describes.
    public let option: LLMModelOption
    /// Snapshot completeness: absent, incomplete (partial/truncated), or fully on disk.
    public let completeness: LocalModelDiskCompleteness
    /// On-disk size of the downloaded weights in bytes, or `nil` when nothing is present.
    public let sizeBytes: Int64?
    /// Whether the model fits the device's ¾-RAM memory budget (else it can't be downloaded/run).
    public let fitsMemoryBudget: Bool

    public var id: String { option.id }

    /// Whether the model's weights are fully present on disk.
    public var isDownloaded: Bool { completeness == .complete }

    public init(
        option: LLMModelOption,
        completeness: LocalModelDiskCompleteness,
        sizeBytes: Int64?,
        fitsMemoryBudget: Bool
    ) {
        self.option = option
        self.completeness = completeness
        self.sizeBytes = sizeBytes
        self.fitsMemoryBudget = fitsMemoryBudget
    }

    public init(option: LLMModelOption, isDownloaded: Bool, sizeBytes: Int64?, fitsMemoryBudget: Bool) {
        self.init(
            option: option,
            completeness: isDownloaded ? .complete : .absent,
            sizeBytes: sizeBytes,
            fitsMemoryBudget: fitsMemoryBudget
        )
    }
}

/// Manages the lifecycle of on-device model weights: listing, downloading, and deleting.
///
/// This is the portable seam the UI talks to; the concrete MLX implementation lives
/// in the `AnAIOdysseyMLX` target (so the heavy MLX dependency stays out of the UI and
/// other layers). On devices that fail the Metal / memory gate (or UI-test
/// mocks), an `UnavailableLocalModelManager` reports everything as unsupported.
///
/// `@MainActor` because its results drive observable SwiftUI state.
@MainActor
public protocol LocalModelManaging: AnyObject {
    /// Whether on-device models can run at all on this device/build (false e.g. on iOS Simulator).
    var isSupported: Bool { get }
    /// Current status of every catalog model (downloaded state, size, budget fit).
    func statuses() -> [LocalModelStatus]
    /// Whether a specific model's weights are present on disk.
    func isDownloaded(_ modelID: String) -> Bool
    /// Downloads the model's weights, reporting fractional progress (0...1) on the main actor.
    /// Throws if the model is unsupported, exceeds the memory budget, or the download fails.
    func download(_ modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws
    /// Removes a model's downloaded weights from disk. No-op if nothing is downloaded.
    func deleteDownload(_ modelID: String) throws
    /// Deletes partial Hub snapshots, blobs, `.incomplete` files, and resume metadata
    /// so the next download cannot continue a leftover slice.
    func discardPartialDownload(_ modelID: String) throws
}

/// Fallback manager when this device cannot run MLX (no Metal, Simulator,
/// catalog models exceed the ¾-RAM budget, or UI-test mocks).
///
/// `isSupported` is false, so Settings omits MLX rows. The Local Models
/// section can still appear for Apple's Foundation Model. Pickers, Compare,
/// and first-run omit every local MLX option. Downloads are refused if
/// anything still calls them.
@MainActor
public final class UnavailableLocalModelManager: LocalModelManaging {
    public init() {}

    /// On-device inference isn't available here.
    public var isSupported: Bool { false }

    /// Catalog entries with no download state, but with the real budget-fit flag for display.
    public func statuses() -> [LocalModelStatus] {
        LLMModelCatalog.models.map { option in
            LocalModelStatus(
                option: option,
                completeness: .absent,
                sizeBytes: nil,
                fitsMemoryBudget: ModelCatalogService.canRun(option)
            )
        }
    }

    /// Nothing is ever downloaded on an unsupported device.
    public func isDownloaded(_ modelID: String) -> Bool { false }

    /// Downloads are unsupported here; steer the user toward a remote provider.
    public func download(_ modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        throw LLMServiceError.generationFailed("On-device models aren't available on this device. Configure a remote provider in Settings.")
    }

    /// Nothing to delete on an unsupported device.
    public func deleteDownload(_ modelID: String) throws {}

    public func discardPartialDownload(_ modelID: String) throws {}
}

/// SwiftUI environment plumbing so views can resolve the active local-model manager.
private struct LocalModelManagerKey: EnvironmentKey {
    static let defaultValue: (any LocalModelManaging)? = nil
}

public extension EnvironmentValues {
    /// The on-device model manager injected by the app, or `nil` when unset (previews).
    var localModelManager: (any LocalModelManaging)? {
        get { self[LocalModelManagerKey.self] }
        set { self[LocalModelManagerKey.self] = newValue }
    }
}

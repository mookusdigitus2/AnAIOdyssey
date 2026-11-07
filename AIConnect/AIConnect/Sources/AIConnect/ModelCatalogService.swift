// SPDX-License-Identifier: MIT
import Foundation

/// Coarse classification of a device's RAM, used to recommend appropriately-sized local models.
public enum ModelMemoryTier: String, Sendable {
    case small
    case medium
    case large

    /// User-facing label describing the RAM range this tier represents.
    public var displayName: String {
        switch self {
        case .small: "Small (< 8 GB RAM)"
        case .medium: "Medium (8–16 GB RAM)"
        case .large: "Large (16+ GB RAM)"
        }
    }
}

/// Recommends on-device MLX models based on available physical memory.
///
/// All entry points are pure functions of the device's RAM and the static
/// `LLMModelCatalog`, so the settings UI can call them freely to suggest a model
/// the device can actually run.
public enum ModelCatalogService {
    /// Hard ceiling on how much of installed RAM a single on-device model may use.
    ///
    /// Models are never allowed to download or load if their estimated footprint
    /// exceeds this fraction of physical memory, leaving the remaining quarter for
    /// the OS, the rest of the app, and the KV cache during generation.
    public static let memoryBudgetFraction = 0.75

    /// Total installed RAM in gigabytes (binary GB, i.e. divided by 1024³).
    public static func physicalMemoryGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// The maximum model footprint (in GB) permitted on this device — ¾ of physical RAM.
    public static func memoryBudgetGB() -> Double {
        physicalMemoryGB() * memoryBudgetFraction
    }

    /// Whether a model is allowed to run here, i.e. its estimate fits the ¾-RAM budget.
    public static func canRun(_ option: LLMModelOption) -> Bool {
        option.estimatedMemoryGB <= memoryBudgetGB()
    }

    /// Buckets the device into a memory tier using fixed 8 GB / 16 GB thresholds.
    public static func memoryTier() -> ModelMemoryTier {
        let gb = physicalMemoryGB()
        if gb < 8 {
            return .small
        }
        if gb < 16 {
            return .medium
        }
        return .large
    }

    /// Filters the catalog to models that comfortably fit the device's memory tier.
    ///
    /// The tier provides a sensible recommendation, but the hard ¾-RAM budget is
    /// always applied on top so a recommendation can never exceed what the device
    /// is actually allowed to load.
    public static func recommendedModels() -> [LLMModelOption] {
        // Cap each tier well under physical RAM to leave headroom for the OS and app.
        let tierFiltered: [LLMModelOption]
        switch memoryTier() {
        case .small:
            tierFiltered = LLMModelCatalog.models.filter { $0.estimatedMemoryGB <= 1.5 }
        case .medium:
            tierFiltered = LLMModelCatalog.models.filter { $0.estimatedMemoryGB <= 3.0 }
        case .large:
            tierFiltered = LLMModelCatalog.models
        }
        // Enforce the absolute ¾-RAM ceiling regardless of tier heuristics.
        return tierFiltered.filter { canRun($0) }
    }

    /// The single best default model id for this device, falling back to the catalog default if nothing fits.
    public static func recommendedModelID() -> String {
        recommendedModels().first?.id ?? LLMModelCatalog.defaultModelID
    }

    /// One-line summary of detected RAM and recommendations for display in settings.
    public static func summaryText() -> String {
        let gb = physicalMemoryGB()
        let tier = memoryTier()
        let models = recommendedModels().map(\.displayName).joined(separator: ", ")
        return String(format: "%.1f GB RAM detected (%@). Recommended: %@", gb, tier.displayName, models)
    }

    /// Compact summary of installed RAM and the per-model size ceiling, shown above
    /// the model-management list so users understand why large models are blocked.
    public static func memorySummaryText() -> String {
        String(
            format: "%.1f GB RAM · on-device models limited to %.1f GB (¾ of memory)",
            physicalMemoryGB(),
            memoryBudgetGB()
        )
    }
}

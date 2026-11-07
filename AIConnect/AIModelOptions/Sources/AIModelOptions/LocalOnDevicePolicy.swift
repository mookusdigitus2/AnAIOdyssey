// SPDX-License-Identifier: MIT
import Foundation

/// Runtime availability of Apple's on-device Foundation Model
/// (`SystemLanguageModel.default`).
///
/// Apple Intelligence being turned off is not the same as ineligible hardware.
public enum AppleFoundationAvailability: String, Sendable, Equatable {
    /// The model can run now and should appear in pickers.
    case available
    /// Eligible hardware, but Apple Intelligence is off in Settings.
    case appleIntelligenceNotEnabled
    /// Eligible hardware; the system is still downloading or preparing the model.
    case modelNotReady
    /// This device cannot run Apple Intelligence / Foundation Models.
    case deviceNotEligible
    /// OS or SDK does not include Foundation Models.
    case unsupportedOS
}

/// Device facts used to decide which local backends to offer. Callers inject
/// live values so the policy stays testable on Linux without Metal or Apple's SDK.
public struct LocalOnDeviceFacts: Equatable, Sendable {
    public var appleFoundation: AppleFoundationAvailability
    public var hasMetalGPU: Bool
    public var isSimulator: Bool
    public var physicalMemoryBytes: UInt64
    /// Estimated footprints of MLX catalog models, in binary GB.
    public var catalogEstimatedMemoryGB: [Double]
    public var memoryBudgetFraction: Double

    public init(
        appleFoundation: AppleFoundationAvailability,
        hasMetalGPU: Bool,
        isSimulator: Bool,
        physicalMemoryBytes: UInt64,
        catalogEstimatedMemoryGB: [Double],
        memoryBudgetFraction: Double = 0.75
    ) {
        self.appleFoundation = appleFoundation
        self.hasMetalGPU = hasMetalGPU
        self.isSimulator = isSimulator
        self.physicalMemoryBytes = physicalMemoryBytes
        self.catalogEstimatedMemoryGB = catalogEstimatedMemoryGB
        self.memoryBudgetFraction = memoryBudgetFraction
    }

    public var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    public var memoryBudgetGB: Double {
        physicalMemoryGB * memoryBudgetFraction
    }
}

/// Decides local-model UI and backends from device facts — never from a blanket
/// "iOS has no local models" rule.
public enum LocalOnDevicePolicy {
    /// Llama 3.2 1B 4-bit catalog estimate.
    public static let mlx1BMemoryGB = 1.2
    /// Llama 3.2 3B 4-bit catalog estimate.
    public static let mlx3BMemoryGB = 2.5

    public static let defaultMLXCatalogMemoryGB = [mlx1BMemoryGB, mlx3BMemoryGB]

    /// Binary GB helper for tests that speak in round RAM sizes.
    public static func bytesForRAMGigabytes(_ gigabytes: Double) -> UInt64 {
        UInt64((gigabytes * 1_073_741_824.0).rounded())
    }

    public static func catalogModelsThatFit(_ facts: LocalOnDeviceFacts) -> [Double] {
        facts.catalogEstimatedMemoryGB.filter { $0 <= facts.memoryBudgetGB }
    }

    public static func shouldOfferMLX(_ facts: LocalOnDeviceFacts) -> Bool {
        facts.hasMetalGPU
            && !facts.isSimulator
            && !catalogModelsThatFit(facts).isEmpty
    }

    /// Picker / Settings: hide only when the device cannot run Apple Intelligence.
    /// Apple Intelligence off and “model not ready” still keep the option.
    public static func shouldOfferAppleFoundation(_ facts: LocalOnDeviceFacts) -> Bool {
        switch facts.appleFoundation {
        case .available, .appleIntelligenceNotEnabled, .modelNotReady:
            true
        case .deviceNotEligible, .unsupportedOS:
            false
        }
    }

    /// Auto-routing and first-run skip: the system model can actually generate.
    public static func appleFoundationIsReady(_ facts: LocalOnDeviceFacts) -> Bool {
        facts.appleFoundation == .available
    }

    /// Settings copy: eligible device, user has Apple Intelligence off.
    public static func shouldShowAppleIntelligenceEnablement(_ facts: LocalOnDeviceFacts) -> Bool {
        facts.appleFoundation == .appleIntelligenceNotEnabled
    }

    /// Settings copy: eligible device, model still downloading or preparing.
    public static func shouldShowAppleModelNotReady(_ facts: LocalOnDeviceFacts) -> Bool {
        facts.appleFoundation == .modelNotReady
    }

    /// Apple manages that download; the app never shows a Download button for it.
    public static func shouldShowAppleDownloadButton(_ facts: LocalOnDeviceFacts) -> Bool {
        _ = facts
        return false
    }

    /// Hide the entire Local Models section only when this device has nothing
    /// local to offer or explain.
    public static func shouldShowLocalModelsSection(_ facts: LocalOnDeviceFacts) -> Bool {
        shouldOfferAppleFoundation(facts) || shouldOfferMLX(facts)
    }

    public static let appleOnDevicePickerLabel = "Apple On-Device"

    public static let appleOnDeviceCapabilityNote =
        "Apple's on-device model is suited to summarizing and rewriting, not a full offline chatbot."

    public static func appleFoundationUserMessage(_ availability: AppleFoundationAvailability) -> String {
        switch availability {
        case .available:
            "Ready on this device."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use on-device AI."
        case .modelNotReady:
            "Getting ready…"
        case .deviceNotEligible:
            "This device can't run Apple's on-device model."
        case .unsupportedOS:
            "This OS doesn't include Apple's on-device model."
        }
    }
}

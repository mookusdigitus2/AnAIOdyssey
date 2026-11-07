// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Metal)
import Metal
#endif

/// Runtime picture of on-device language-model backends for **this** device.
///
/// Support is decided from live facts (`LocalOnDevicePolicy`), never from a
/// blanket "iOS has no local models" rule.
///
/// **Apple On-Device** (`SystemLanguageModel.default.availability`):
/// `.deviceNotEligible` hides the option. `.appleIntelligenceNotEnabled` keeps
/// it and shows enablement copy. `.modelNotReady` keeps it with “Getting ready…”
/// and no Download button. `.available` is the runnable picker option.
///
/// **MLX** runs where there is a Metal GPU, the process is not a Simulator,
/// and at least one catalog model fits the ¾-RAM budget. A supported device
/// with nothing downloaded still shows Download. UI-test mocks inject
/// ``UnavailableLocalModelManager`` and hide MLX even on a capable Mac.
public enum OnDeviceLanguageModelSupport {
    public static var liveFacts: LocalOnDeviceFacts {
        LocalOnDeviceFacts(
            appleFoundation: appleFoundationAvailability,
            hasMetalGPU: hasMetalGPU,
            isSimulator: isSimulator,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            catalogEstimatedMemoryGB: LLMModelCatalog.models.map(\.estimatedMemoryGB)
        )
    }

    public static var appleFoundationAvailability: AppleFoundationAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .modelNotReady
            case .unavailable:
                return .deviceNotEligible
            @unknown default:
                return .unsupportedOS
            }
        }
        #endif
        return .unsupportedOS
    }

    public static var hasMetalGPU: Bool {
        #if canImport(Metal)
        MTLCreateSystemDefaultDevice() != nil
        #else
        false
        #endif
    }

    public static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// MLX local inference is implemented for this live device (Metal + memory).
    public static var mlxIsAvailable: Bool {
        LocalOnDevicePolicy.shouldOfferMLX(liveFacts)
    }

    public static var appleFoundationModelsAreAvailable: Bool {
        LocalOnDevicePolicy.appleFoundationIsReady(liveFacts)
    }

    /// Show Apple On-Device in Settings / pickers (not device-ineligible).
    public static var shouldOfferAppleFoundation: Bool {
        LocalOnDevicePolicy.shouldOfferAppleFoundation(liveFacts)
    }

    /// The system model can generate now — used for auto-routing and first-run skip.
    public static var appleFoundationIsReady: Bool {
        LocalOnDevicePolicy.appleFoundationIsReady(liveFacts)
    }

    public static var shouldShowAppleIntelligenceEnablement: Bool {
        LocalOnDevicePolicy.shouldShowAppleIntelligenceEnablement(liveFacts)
    }

    public static var shouldShowAppleModelNotReady: Bool {
        LocalOnDevicePolicy.shouldShowAppleModelNotReady(liveFacts)
    }

    public static var shouldOfferLocalMLX: Bool { mlxIsAvailable }

    /// Runtime: this live manager can download and run local MLX. False on
    /// UI-test mocks that inject ``UnavailableLocalModelManager``, and on
    /// devices that fail the Metal / memory gate.
    @MainActor
    public static func shouldOfferLocalMLX(manager: (any LocalModelManaging)?) -> Bool {
        guard let manager else { return false }
        return shouldOfferLocalMLX && manager.isSupported
    }

    @MainActor
    public static func shouldShowLocalModelsSection(manager: (any LocalModelManaging)?) -> Bool {
        let facts = liveFacts
        return LocalOnDevicePolicy.shouldOfferAppleFoundation(facts)
            || shouldOfferLocalMLX(manager: manager)
    }
}

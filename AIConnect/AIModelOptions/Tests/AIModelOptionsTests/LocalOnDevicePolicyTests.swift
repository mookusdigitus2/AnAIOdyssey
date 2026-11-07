// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class LocalOnDevicePolicyTests: XCTestCase {
    private let catalog = LocalOnDevicePolicy.defaultMLXCatalogMemoryGB

    func testIPhone15ProWithAppleIntelligenceOnOffersFoundationAndMLX() {
        let facts = facts(
            apple: .available,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertTrue(LocalOnDevicePolicy.appleFoundationIsReady(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertEqual(LocalOnDevicePolicy.catalogModelsThatFit(facts), catalog)
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowAppleIntelligenceEnablement(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowAppleDownloadButton(facts))
    }

    func testIPhoneAir12GBOffersFoundationAndBothMLXSizes() {
        let facts = facts(
            apple: .available,
            ramGB: 12,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertEqual(LocalOnDevicePolicy.catalogModelsThatFit(facts), catalog)
    }

    func testIPhone16LineWithIntelligenceOnOffersFoundation() {
        let facts = facts(
            apple: .available,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferMLX(facts))
    }

    func testIPadM1OrA17ProOffersFoundationWhenAvailable() {
        let facts = facts(
            apple: .available,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testAppleIntelligenceOffKeepsOptionWithEnablementCopy() {
        let facts = facts(
            apple: .appleIntelligenceNotEnabled,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertFalse(LocalOnDevicePolicy.appleFoundationIsReady(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowAppleIntelligenceEnablement(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowAppleDownloadButton(facts))
        XCTAssertEqual(
            LocalOnDevicePolicy.appleFoundationUserMessage(.appleIntelligenceNotEnabled),
            "Turn on Apple Intelligence in Settings to use on-device AI."
        )
        XCTAssertNotEqual(
            LocalOnDevicePolicy.appleFoundationUserMessage(.appleIntelligenceNotEnabled),
            LocalOnDevicePolicy.appleFoundationUserMessage(.deviceNotEligible)
        )
    }

    func testModelNotReadyShowsGettingReadyWithoutDownload() {
        let facts = facts(
            apple: .modelNotReady,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertFalse(LocalOnDevicePolicy.appleFoundationIsReady(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowAppleModelNotReady(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowAppleDownloadButton(facts))
        XCTAssertEqual(
            LocalOnDevicePolicy.appleFoundationUserMessage(.modelNotReady),
            "Getting ready…"
        )
    }

    func testDeviceNotEligibleHidesAppleOnDeviceOption() {
        let facts = facts(
            apple: .deviceNotEligible,
            ramGB: 8,
            metal: true,
            simulator: false
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertFalse(LocalOnDevicePolicy.appleFoundationIsReady(facts))
    }

    func testIneligibleIPhoneWithoutEnoughRAMHidesLocalSection() {
        // Older ineligible phone with ~2 GB: ¾ budget is 1.5 GB, 1B (1.2) fits.
        // Drop to 1 GB so neither MLX size fits and FM is ineligible.
        let facts = facts(
            apple: .deviceNotEligible,
            ramGB: 1,
            metal: true,
            simulator: false
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testIPhoneXR3GBGetsMLX1BOnlyNoFoundation() {
        let facts = facts(
            apple: .deviceNotEligible,
            ramGB: 3,
            metal: true,
            simulator: false
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertEqual(LocalOnDevicePolicy.catalogModelsThatFit(facts), [LocalOnDevicePolicy.mlx1BMemoryGB])
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testSimulatorNeverOffersMLXEvenWithMetalAndRAM() {
        let facts = facts(
            apple: .deviceNotEligible,
            ramGB: 16,
            metal: true,
            simulator: true
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testNoMetalMeansNoMLX() {
        let facts = facts(
            apple: .unsupportedOS,
            ramGB: 16,
            metal: false,
            simulator: false
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testMacWithMetalOffersMLXRegardlessOfFoundation() {
        let facts = facts(
            apple: .unsupportedOS,
            ramGB: 16,
            metal: true,
            simulator: false
        )
        XCTAssertFalse(LocalOnDevicePolicy.shouldOfferAppleFoundation(facts))
        XCTAssertTrue(LocalOnDevicePolicy.shouldOfferMLX(facts))
        XCTAssertEqual(LocalOnDevicePolicy.catalogModelsThatFit(facts), catalog)
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowLocalModelsSection(facts))
    }

    func testIOSIsNotABlanketBan() {
        // The same 8 GB Metal iPhone facts offer local models; an ineligible
        // 1 GB device does not. Platform name never appears in the policy.
        let eligible = facts(apple: .available, ramGB: 8, metal: true, simulator: false)
        let ineligible = facts(apple: .deviceNotEligible, ramGB: 1, metal: true, simulator: false)
        XCTAssertTrue(LocalOnDevicePolicy.shouldShowLocalModelsSection(eligible))
        XCTAssertFalse(LocalOnDevicePolicy.shouldShowLocalModelsSection(ineligible))
    }

    private func facts(
        apple: AppleFoundationAvailability,
        ramGB: Double,
        metal: Bool,
        simulator: Bool
    ) -> LocalOnDeviceFacts {
        LocalOnDeviceFacts(
            appleFoundation: apple,
            hasMetalGPU: metal,
            isSimulator: simulator,
            physicalMemoryBytes: LocalOnDevicePolicy.bytesForRAMGigabytes(ramGB),
            catalogEstimatedMemoryGB: catalog
        )
    }
}

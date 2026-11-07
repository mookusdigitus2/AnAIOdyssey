// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyCore

/// Settings > About > Acknowledgements reads `ThirdPartyNotices/` from the app
/// bundle. These tests keep that folder complete and in sync with the repo.
final class ThirdPartyNoticesTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var noticesDirectory: URL { appRoot.appendingPathComponent(ThirdPartyNotices.folderName) }

    private func manifest() throws -> ThirdPartyNoticesManifest {
        try ThirdPartyNotices.load(directory: noticesDirectory)
    }

    func testEveryResolvedPackageHasAnEntry() throws {
        let resolved = appRoot.appendingPathComponent(
            "AnAIOdyssey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        let identities = pins.compactMap { $0["identity"] as? String }
        XCTAssertFalse(identities.isEmpty)
        let ids = Set(try manifest().packages.map(\.id))
        for identity in identities {
            XCTAssertTrue(ids.contains(identity), "\(identity) is resolved but missing from Acknowledgements")
        }
    }

    func testOurOwnMITPackagesAndOdysseusAreListed() throws {
        let packages = try manifest().packages
        for id in ["aiconnect", "aiconnectvoice", "odysseus"] {
            let entry = try XCTUnwrap(packages.first { $0.id == id }, id)
            XCTAssertEqual(entry.license, "MIT", id)
        }
        let odysseus = try XCTUnwrap(packages.first { $0.id == "odysseus" })
        let text = try ThirdPartyNotices.text(of: XCTUnwrap(odysseus.files.first), in: noticesDirectory)
        XCTAssertTrue(text.contains("Copyright (c) 2025 Odysseus Contributors"))
    }

    func testEveryListedFileExistsAndIsNotEmpty() throws {
        let m = try manifest()
        for entry in m.packages + [m.app] {
            XCTAssertFalse(entry.files.isEmpty, entry.id)
            for file in entry.files {
                let text = try ThirdPartyNotices.text(of: file, in: noticesDirectory)
                XCTAssertGreaterThan(text.count, 100, "\(entry.id): \(file)")
            }
        }
    }

    func testApacheLicensedPackagesShipTheFullLicenseText() throws {
        for entry in try manifest().packages where entry.license == "Apache-2.0" {
            let text = try ThirdPartyNotices.text(of: XCTUnwrap(entry.files.first), in: noticesDirectory)
            XCTAssertTrue(text.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"), entry.id)
        }
    }

    /// The bundled copies are generated; they must match the files they came from.
    func testBundledCopiesMatchTheRepositoryLicenses() throws {
        let openSource = appRoot.deletingLastPathComponent()
        let pairs: [(String, URL)] = [
            ("anaiodyssey-LICENSE.txt", appRoot.appendingPathComponent("LICENSE")),
            ("anaiodyssey-LICENSE.appstore.txt", appRoot.appendingPathComponent("LICENSE.appstore")),
            ("aiconnect-LICENSE.txt", openSource.appendingPathComponent("AIConnect/LICENSE")),
            ("aiconnectvoice-LICENSE.txt", openSource.appendingPathComponent("AIConnectVoice/LICENSE")),
        ]
        for (bundled, source) in pairs {
            XCTAssertEqual(try ThirdPartyNotices.text(of: bundled, in: noticesDirectory),
                           try String(contentsOf: source, encoding: .utf8),
                           "\(bundled) is stale; run Scripts/generate_third_party_notices.py")
        }
    }

    func testAppLicenseIsAGPLWithTheAppStorePermission() throws {
        let app = try manifest().app
        XCTAssertEqual(app.license, "AGPL-3.0-or-later")
        let texts = try app.files.map { try ThirdPartyNotices.text(of: $0, in: noticesDirectory) }
        XCTAssertTrue(texts.contains { $0.contains("GNU AFFERO GENERAL PUBLIC LICENSE") })
        XCTAssertTrue(texts.contains { $0.contains("As additional permission under section 7") })
    }
}

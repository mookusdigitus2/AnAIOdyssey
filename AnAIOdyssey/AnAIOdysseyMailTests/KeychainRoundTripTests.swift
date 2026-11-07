// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
@testable import AnAIOdysseyMail

final class KeychainRoundTripTests: XCTestCase {
    private let service = "com.example.anaiodyssey.tests.keychain"

    override func tearDown() {
        KeychainStore.delete(service: service, account: "acct")
    }

    /// TokenStore writes then verifies by reading back. On iOS the legacy-copy
    /// cleanup deleted the fresh item, so the verify read came back empty.
    func testWriteThenReadReturnsSameData() throws {
        let data = Data("token-\(UUID().uuidString)".utf8)
        guard KeychainStore.set(data, service: service, account: "acct") else {
            throw XCTSkip("Keychain unavailable in this unsigned test host")
        }
        XCTAssertEqual(KeychainStore.get(service: service, account: "acct"), data)
    }

    func testLegacyKeychainIsSeparateOnlyOnMac() {
        #if os(iOS)
        XCTAssertFalse(KeychainStore.hasSeparateLegacyKeychain)
        #else
        XCTAssertTrue(KeychainStore.hasSeparateLegacyKeychain)
        #endif
    }
}

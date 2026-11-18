import Foundation
import XCTest
@testable import PiMobileCore

final class LegacyPairingTests: XCTestCase {
    private let relay = "wss://original.example/pi/client"
    private let token = String(repeating: "a", count: 64)
    private let gateway = "CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testSameRelayUpgradeRestoresOriginalIdentityAndNextBuildNeedsNoMigrationHint() throws {
        let io = try legacyItems()
        let oldPrivate = try XCTUnwrap(io.items["pi-mobile.e2ePriv"])
        let store = io.store(legacyEndpoint: relay)
        let saved = try XCTUnwrap(store.restore(), "Upgrade should recognize the old three-item pairing")
        XCTAssertEqual(saved.endpoint.absoluteString, relay)
        XCTAssertEqual(saved.token, token)
        XCTAssertEqual(saved.key.privateRaw, oldPrivate)
        XCTAssertEqual(saved.key.gatewayPublic, gateway)
        let next = try XCTUnwrap(io.store(legacyEndpoint: nil).restore())
        XCTAssertEqual(next.key.publicKey, saved.key.publicKey)
        XCTAssertEqual(next.endpoint, saved.endpoint)
        store.clear()
        XCTAssertTrue(io.items.isEmpty)
        XCTAssertNil(store.restore())
    }

    func testMissingTrustedOriginOrIncompleteCredentialsLeavesLegacyItemsIntact() throws {
        for endpoint in [nil, "", "ws://original.example/pi/client", "wss://original.example/other"] as [String?] {
            let io = try legacyItems()
            let before = io.items
            XCTAssertNil(io.store(legacyEndpoint: endpoint).restore())
            XCTAssertEqual(io.items, before)
        }
        for (account, badValue) in [("pi-mobile.e2ePriv", nil), ("pi-mobile.gatewayPub", "invalid"), ("pi-mobile.deviceToken", "short")] as [(String, String?)] {
            let io = try legacyItems()
            io.items[account] = badValue
            let before = io.items
            XCTAssertNil(io.store(legacyEndpoint: relay).restore())
            XCTAssertEqual(io.items, before)
        }
    }

    func testExistingPairingAlwaysWinsEvenWhenUnreadableOrForAnotherRelay() throws {
        let io = try legacyItems()
        let store = io.store(legacyEndpoint: relay)
        io.items["pi-mobile.pairing.v1"] = "damaged record"
        XCTAssertNil(store.restore())
        XCTAssertEqual(io.items["pi-mobile.pairing.v1"], "damaged record")
        let newer = try XCTUnwrap(E2EKey(gatewayPublicKey: gateway))
        let endpoint = try XCTUnwrap(URL(string: "wss://new.example/pi/client"))
        let newToken = String(repeating: "b", count: 64)
        XCTAssertTrue(store.save(endpoint: endpoint, token: newToken, key: newer))
        let current = try XCTUnwrap(store.restore())
        XCTAssertEqual(current.endpoint, endpoint)
        XCTAssertEqual(current.token, newToken)
        XCTAssertEqual(current.key.publicKey, newer.publicKey)
    }

    func testFailedInsertKeepsLegacyCredentialsForRetry() throws {
        let io = try legacyItems()
        io.allowInsert = false
        let before = io.items
        let store = io.store(legacyEndpoint: relay)
        XCTAssertNil(store.restore())
        XCTAssertEqual(io.items, before)
        io.allowInsert = true
        XCTAssertNotNil(store.restore())
    }

    private func legacyItems() throws -> PairingAccounts {
        let key = try XCTUnwrap(E2EKey(gatewayPublicKey: gateway))
        let io = PairingAccounts()
        io.items = ["pi-mobile.deviceToken": token, "pi-mobile.e2ePriv": key.privateRaw, "pi-mobile.gatewayPub": gateway]
        return io
    }
}

private final class PairingAccounts {
    var items: [String: String] = [:]
    var allowInsert = true

    func store(legacyEndpoint: String?) -> PairingStore {
        PairingStore.accounts(legacyEndpoint: legacyEndpoint, read: { self.items[$0] }, write: { value, key in
            self.items[key] = value
            return true
        }, insert: { value, key in
            guard self.allowInsert, self.items[key] == nil else { return false }
            self.items[key] = value
            return true
        }, delete: { self.items.removeValue(forKey: $0) })
    }
}

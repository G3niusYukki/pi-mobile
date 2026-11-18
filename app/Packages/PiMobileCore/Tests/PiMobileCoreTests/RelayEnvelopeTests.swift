import XCTest
@testable import PiMobileCore

@MainActor
final class RelayEnvelopeTests: XCTestCase {
    func testRPCResponsesAndEventsRequireAuthenticatedContents() async {
        let client = RelayClient()
        var responseCount = 0
        var eventCount = 0
        client.onResponse = { _ in responseCount += 1 }
        client.onEvent = { _ in eventCount += 1 }

        await client.handle(["type": "rpc_response", "success": true])
        await client.handle(["type": "rpc_response", "sealed": "invalid"])
        await client.handle(["type": "event", "event": ["type": "agent_end"]])

        XCTAssertEqual(responseCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testGatewayKeyAnnouncementNeedsAnExistingPairing() async {
        let client = RelayClient()
        await client.handle(["type": "status", "state": "idle", "needsPairingKey": true])
        XCTAssertEqual(client.state, .idle)
    }
}

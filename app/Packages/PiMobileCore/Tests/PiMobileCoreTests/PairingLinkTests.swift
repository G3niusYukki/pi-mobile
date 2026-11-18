import XCTest
@testable import PiMobileCore

private let code = "0123456789abcdef0123456789abcdef"
private let gatewayKey = "CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" // X25519 base point
private var fragment: String { "\(code).\(gatewayKey)" }

final class PairingLinkTests: XCTestCase {
    func testHTTPSLinkUsesOnlyItsOrigin() throws {
        for host in ["relay.example", "relay.example:8443", "[::1]:443"] {
            let link = try PairingLink("  https://\(host)/pi/pair#\(fragment)\n")
            XCTAssertEqual(link.endpoint.absoluteString, "wss://\(host)/pi/client")
            XCTAssertEqual(link.code, code)
            XCTAssertEqual(link.key.gatewayPublic, gatewayKey)
        }
    }

    func testRawPairingCodeRequiresKnownSecureEndpoint() throws {
        let saved = URL(string: "wss://known.example:9443/pi/client")!
        XCTAssertEqual(try PairingLink(fragment, knownEndpoint: saved).endpoint, saved)
        XCTAssertThrowsError(try PairingLink(fragment)) { error in
            XCTAssertTrue(error.localizedDescription.contains("完整"))
        }
        XCTAssertThrowsError(try PairingLink(fragment, knownEndpoint: URL(string: "ws://known.example/pi/client")))
    }

    func testInvalidLinkCannotFallBackToKnownRelayOrExtractFragment() {
        let saved = URL(string: "wss://saved.example/pi/client")!
        for input in ["http://r.example/pi/pair", "wss://r.example/pi/pair", "//r.example/pi/pair",
                      "https://user:pw@r.example/pi/pair", "https://@r.example/pi/pair", "https:///pi/pair",
                      "https://r.example:0/pi/pair", "https://r.example:65536/pi/pair", "https://r.example:/pi/pair",
                      "https://r.example%2Felse/pi/pair", "https://r.example\\@else.example/pi/pair",
                      "https://[invalid]/pi/pair", "https://r.example/pi%2Fpair", "https://r.example/pi/pair/",
                      "https://r.example/pi/pair?", "https://r.example/pi/pair?x=1", "https://r.example/other", "text"] {
            XCTAssertThrowsError(try PairingLink(input + "#" + fragment, knownEndpoint: saved), input)
        }
        for malformed in ["", code, "." + gatewayKey, "g" + String(code.dropFirst()) + "." + gatewayKey,
                          fragment + "=", fragment + "#", fragment + ".extra", String(fragment.dropLast()),
                          String(fragment.dropLast()) + "B", code + "." + String(repeating: "A", count: 43)] {
            XCTAssertThrowsError(try PairingLink("https://r.example/pi/pair#" + malformed), malformed)
        }
    }

    @MainActor
    func testFailedPairingKeepsTheOldEndpointTokenAndE2EIdentity() async throws {
        let io = PairingFixture()
        let client = io.client()
        let deviceToken = String(repeating: "a", count: 64)
        client.pair(token: "https://old.example:8443/pi/pair#" + fragment)
        let oldSocket = try XCTUnwrap(io.sockets.last)
        let firstFrame = expectation(description: "first pairing frame")
        oldSocket.didSend = { frame in if frame["type"] == "pair" { firstFrame.fulfill() } }
        await fulfillment(of: [firstFrame], timeout: 2)
        let oldPublicKey = try XCTUnwrap(oldSocket.frames.first?["pub"])
        XCTAssertEqual(oldSocket.frames.first?["token"], code)
        XCTAssertNil(io.saved)
        await client.handle(["type": "paired", "deviceToken": deviceToken])
        let saved = try XCTUnwrap(io.saved)
        XCTAssertTrue(client.hasPairing)

        client.pair(token: "https://new.example/pi/pair#" + fragment)
        XCTAssertEqual(io.requests.last?.url?.absoluteString, "wss://new.example/pi/client")
        XCTAssertNil(io.requests.last?.value(forHTTPHeaderField: "Authorization"))
        await client.handle(["type": "hello"])
        await client.handle(["type": "status", "state": "running"])
        XCTAssertFalse(client.isConnected)
        await client.handle(["type": "error", "message": "pair token invalid or expired"])
        await client.handle(["type": "paired", "deviceToken": String(repeating: "b", count: 64)])
        XCTAssertEqual(io.saved, saved)

        let restored = io.client()
        restored.connect()
        XCTAssertEqual(io.requests.last?.url?.absoluteString, "wss://old.example:8443/pi/client")
        XCTAssertEqual(io.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + deviceToken)
        await restored.handle(["type": "paired", "deviceToken": deviceToken])
        XCTAssertEqual(io.sockets.last?.frames.last?["pub"], oldPublicKey)
        restored.pair(token: fragment)
        XCTAssertEqual(io.requests.last?.url?.host, "old.example")
        XCTAssertNil(io.requests.last?.value(forHTTPHeaderField: "Authorization"))
        restored.disconnect()
    }

    @MainActor
    func testReplacingAQueuedPairSendsOnlyTheLatestCodeAndResumesItsOrigin() async throws {
        let io = PairingFixture()
        let client = io.client(endpoint: "wss://configured.example/pi/client")
        client.pair(token: fragment)
        let superseded = try XCTUnwrap(io.sockets.last)
        XCTAssertEqual(io.requests.last?.url?.host, "configured.example")
        let latestCode = String(repeating: "1", count: 32)
        client.pair(token: "https://latest.example:9443/pi/pair#\(latestCode).\(gatewayKey)")
        let sent = expectation(description: "latest code sent")
        io.sockets.last?.didSend = { frame in
            if frame["type"] == "pair" { XCTAssertEqual(frame["token"], latestCode); sent.fulfill() }
        }
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertTrue(superseded.frames.isEmpty)
        let token = String(repeating: "c", count: 64)
        await client.handle(["type": "paired", "deviceToken": token])
        client.connect()
        XCTAssertEqual(io.requests.last?.url?.absoluteString, "wss://latest.example:9443/pi/client")
        XCTAssertEqual(io.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        client.disconnect()
    }

    @MainActor
    func testResetDiscardsPairAcknowledgementStillSendingItsPublicKey() async throws {
        let io = PairingFixture()
        let client = io.client()
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        let socket = try XCTUnwrap(io.sockets.last)
        let suspended = expectation(description: "pair_pub in flight")
        var release: CheckedContinuation<Void, Never>?
        socket.onPairPub = { await withCheckedContinuation { release = $0; suspended.fulfill() } }
        let pending = Task { await client.handle(["type": "paired", "deviceToken": String(repeating: "a", count: 64)]) }
        await fulfillment(of: [suspended], timeout: 2)
        client.resetPairing()
        release?.resume()
        await pending.value
        XCTAssertFalse(client.hasPairing)
        XCTAssertNil(io.saved)
        XCTAssertEqual(client.state, .idle)
        client.pair(token: fragment)
        XCTAssertEqual(io.requests.count, 1)
        XCTAssertTrue(client.lastError?.contains("完整") == true)
    }

    @MainActor
    func testInvalidAcknowledgementOrFailedStorageCannotReplaceThePairing() async throws {
        let io = PairingFixture()
        let client = io.client()
        let token = String(repeating: "a", count: 64)
        client.pair(token: "https://old.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": token])
        let saved = try XCTUnwrap(io.saved)
        client.connect()
        await client.handle(["type": "paired", "deviceToken": String(repeating: "b", count: 64)])
        XCTAssertEqual(client.state, .error)
        XCTAssertEqual(io.saved, saved)
        client.pair(token: "https://other.example/pi/pair#" + fragment)
        io.allowWrite = false
        await client.handle(["type": "paired", "deviceToken": String(repeating: "b", count: 64)])
        XCTAssertEqual(client.state, .error)
        XCTAssertEqual(io.saved, saved)
        client.resetPairing()
        XCTAssertNil(io.saved)
        XCTAssertFalse(io.client().hasPairing)
    }

    func testKeyAgreementRejectsLowOrderGatewayKey() {
        let lowOrder = String(repeating: "A", count: 43)
        XCTAssertNil(E2EKey(gatewayPublicKey: lowOrder))
        XCTAssertNil(E2EKey(privateKeyBase64Url: String(repeating: "M", count: 43), gatewayPublicKey: lowOrder))
    }
}

@MainActor
private final class PairingFixture {
    var saved: String?
    var allowWrite = true
    var requests: [URLRequest] = []
    var sockets: [TestRelaySocket] = []

    func client(endpoint: String? = nil) -> RelayClient {
        let store = PairingStore(read: { self.saved }, write: { value in
            guard self.allowWrite else { return false }
            self.saved = value
            return true
        }, clear: { self.saved = nil })
        return RelayClient(endpoint: endpoint, store: store) { request in
            let socket = TestRelaySocket()
            self.requests.append(request)
            self.sockets.append(socket)
            return socket
        }
    }
}

@MainActor
private final class TestRelaySocket: RelaySocket {
    var frames: [[String: String]] = []
    var didSend: (([String: String]) -> Void)?
    var onPairPub: (() async -> Void)?

    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else {
            XCTFail("Expected a text control frame")
            return
        }
        frames.append(frame)
        didSend?(frame)
        if frame["type"] == "pair_pub" { await onPairPub?() }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

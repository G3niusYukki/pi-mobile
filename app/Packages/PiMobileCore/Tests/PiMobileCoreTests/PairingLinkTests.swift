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

    @MainActor
    func testForegroundChecksReplaceAHalfOpenSocketWithoutReplayingAnRPC() async throws {
        let io = PairingFixture()
        let client = io.client(pongTimeout: .milliseconds(150))
        defer { client.disconnect() }
        let token = String(repeating: "c", count: 64)
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": token])
        let first = try XCTUnwrap(io.sockets.last)
        var oldPong: (@Sendable (Error?) -> Void)?
        first.onPing = { oldPong = $0 }
        let replaced = expectation(description: "resume using the saved credential")
        io.didOpen = { replaced.fulfill() }
        client.setForeground(false)
        client.setForeground(true)
        await fulfillment(of: [replaced], timeout: 2)
        let second = try XCTUnwrap(io.sockets.last)
        XCTAssertFalse(second === first)
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(io.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        await client.handle(["type": "paired", "deviceToken": token])
        oldPong?(URLError(.networkConnectionLost))
        await Task.yield()
        XCTAssertTrue(client.isConnected)
        XCTAssertFalse(second.cancelled, "A callback from the old socket must not close the replacement")
        XCTAssertEqual(second.frames.compactMap { $0["type"] }, ["pair_pub"])
    }

    @MainActor
    func testHealthyAndBackgroundSocketsSurviveForegroundChecks() async throws {
        let io = PairingFixture()
        let client = io.client(pongTimeout: .milliseconds(150))
        defer { client.disconnect() }
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": String(repeating: "c", count: 64)])
        let first = try XCTUnwrap(io.sockets.last)
        let pinged = expectation(description: "one foreground ping for repeated activation")
        var pending: (@Sendable (Error?) -> Void)?
        first.onPing = { pending = $0; pinged.fulfill() }
        client.setForeground(false)
        client.setForeground(true)
        client.setForeground(true)
        await fulfillment(of: [pinged], timeout: 1)
        client.setForeground(false)
        pending?(URLError(.networkConnectionLost)) // A late result after backgrounding is stale.
        let pingedAgain = expectation(description: "probe the same connection on return")
        first.onPing = { complete in complete(nil); pingedAgain.fulfill() }
        client.setForeground(true)
        await fulfillment(of: [pingedAgain], timeout: 1)
        let noReplace = expectation(description: "responsive socket kept")
        noReplace.isInverted = true
        io.didOpen = { noReplace.fulfill() }
        await fulfillment(of: [noReplace], timeout: 0.25)
        XCTAssertTrue(client.isConnected)
        XCTAssertFalse(first.cancelled)
    }

    @MainActor
    func testQuietConnectionLostWhileChatStaysOpenRecoversOnItsOwn() async throws {
        let io = PairingFixture()
        let client = io.client(pongTimeout: .milliseconds(120), heartbeatInterval: .milliseconds(100))
        defer { client.disconnect() }
        let token = String(repeating: "b", count: 64)
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": token])
        let first = try XCTUnwrap(io.sockets.last)
        first.onPing = { _ in } // receive() is still suspended and the radio silently lost the stream.
        let resumed = expectation(description: "recover an idle stream while still foreground")
        io.didOpen = { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(io.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
    }

    @MainActor
    func testGatewayReturningRenewsEncryptionOnTheExistingPhoneSocket() async throws {
        let io = PairingFixture()
        let client = io.client()
        defer { client.disconnect() }
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": String(repeating: "a", count: 64)])
        let phone = try XCTUnwrap(io.sockets.last)
        let publicKey = try XCTUnwrap(phone.frames.last?["pub"])
        await client.handle(["type": "status", "state": "unknown"])
        XCTAssertFalse(client.isConnected)
        // Both relay and gateway may independently announce the same recovery.
        var restorations = 0
        var connected = false
        client.onConnectionChange = { _, _ in
            let next = client.isConnected
            if !connected && next { restorations += 1 }
            connected = next
        }
        for _ in 0..<2 {
            await client.handle(["type": "status", "state": "idle", "needsPairingKey": true])
        }
        XCTAssertEqual(io.sockets.count, 1, "An upstream reconnect must not interrupt the downstream socket")
        XCTAssertFalse(phone.cancelled)
        XCTAssertEqual(phone.frames.last, ["type": "pair_pub", "pub": publicKey])
        XCTAssertGreaterThan(phone.frames.filter { $0["type"] == "pair_pub" }.count, 1)
        XCTAssertEqual(restorations, 1)
        XCTAssertTrue(client.isConnected)
    }

    @MainActor
    func testLostPublicKeyWriteDuringResumeRetriesTheSavedPairing() async throws {
        let io = PairingFixture()
        let client = io.client()
        defer { client.disconnect() }
        let token = String(repeating: "a", count: 64)
        client.pair(token: "https://relay.example/pi/pair#" + fragment)
        await client.handle(["type": "paired", "deviceToken": token])
        let saved = try XCTUnwrap(io.saved)
        client.connect()
        io.sockets.last?.onPairPub = { throw URLError(.networkConnectionLost) }
        let resumed = expectation(description: "retry resume after the network drops during handshake")
        io.didOpen = { resumed.fulfill() }
        await client.handle(["type": "paired", "deviceToken": token])
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(io.saved, saved)
        XCTAssertEqual(io.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        await client.handle(["type": "paired", "deviceToken": token])
        XCTAssertTrue(client.isConnected)
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

    var didOpen: (() -> Void)?

    func client(endpoint: String? = nil, pongTimeout: Duration = .seconds(8), heartbeatInterval: Duration = .seconds(20)) -> RelayClient {
        let store = PairingStore(read: { self.saved }, write: { value in
            guard self.allowWrite else { return false }
            self.saved = value
            return true
        }, clear: { self.saved = nil })
        return RelayClient(endpoint: endpoint, store: store, pongTimeout: pongTimeout, heartbeatInterval: heartbeatInterval) { request in
            let socket = TestRelaySocket()
            self.requests.append(request)
            self.sockets.append(socket)
            self.didOpen?()
            return socket
        }
    }
}

@MainActor
private final class TestRelaySocket: RelaySocket {
    var frames: [[String: String]] = []
    var didSend: (([String: String]) -> Void)?
    var onPairPub: (() async throws -> Void)?
    var onPing: ((@escaping @Sendable (Error?) -> Void) -> Void)?
    var cancelled = false

    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { cancelled = true }
    func ping(_ completion: @escaping @Sendable (Error?) -> Void) {
        if let onPing { onPing(completion) } else { completion(nil) }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else {
            XCTFail("Expected a text control frame")
            return
        }
        frames.append(frame)
        didSend?(frame)
        if frame["type"] == "pair_pub" { try await onPairPub?() }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

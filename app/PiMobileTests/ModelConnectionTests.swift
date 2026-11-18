import CryptoKit
import XCTest
@testable import PiMobileCore
@testable import PiMobile

/// Exercise the production handshake, encrypted wire commands, and app callbacks in memory.
@MainActor
final class ModelConnectionTests: XCTestCase {
    func testOldStateCannotMoveCheckmarkWhileModelChangeIsInFlight() async throws {
        let f = try await SessionFixture.ready()
        f.app.resume()
        let old = try await f.next("get_state")
        f.app.chooseModel(f.option("b"))
        let change = try await f.next("set_model")
        await f.state(old, model: "a")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        XCTAssertFalse(f.app.canSend, "A prompt must wait for its selected model")
        f.app.draft = "keep this draft"
        XCTAssertFalse(f.app.send())
        XCTAssertEqual(f.app.draft, "keep this draft")
        await f.reply(change)
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
    }

    func testRapidTapsCoalesceAndRejectToLastAcknowledgedModel() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let first = try await f.next("set_model")
        f.app.chooseModel(f.option("c"))
        f.app.chooseModel(f.option("d"))
        f.app.chooseModel(f.option("d"))
        await f.drain()
        XCTAssertFalse(f.socket.commands.contains { $0["type"] as? String == "set_model" })
        await f.reply(first)
        XCTAssertEqual(f.app.selectedModel, "fixture/d")
        let last = try await f.next("set_model")
        XCTAssertEqual(last["modelId"] as? String, "d")
        await f.reply(last, error: "Model unavailable")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        XCTAssertEqual(f.app.errorMessage, "Model unavailable")
        XCTAssertTrue(f.app.canSend)
    }

    func testSnapshotAlreadyInFlightAtAcknowledgementCannotUndoSelection() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let change = try await f.next("set_model")
        f.app.resume()
        let old = try await f.next("get_state")
        await f.reply(change)
        await f.state(old, model: "a")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        let latest = try await f.next("get_state")
        await f.state(latest, model: "b", thinking: "medium")
        XCTAssertEqual(f.app.thinking, "medium", "Pi may change the supported effort with the model")
    }

    func testPromptCannotDiscardMacsEffectiveThinkingLevel() async throws {
        let f = try await SessionFixture.ready()
        f.app.setThinking("max")
        await f.reply(try await f.next("set_thinking_level"))
        let readback = try await f.next("get_state")
        f.app.draft = "next question"
        XCTAssertTrue(f.app.send())
        await f.state(readback, model: "a", thinking: "off")
        XCTAssertEqual(f.app.thinking, "off", "Use the level the active model actually supports")
        XCTAssertEqual(f.app.connection, .running, "The stale idle snapshot must not finish the new prompt")
    }

    func testPrePromptSettingsSnapshotCannotUndoANewerAcknowledgement() async throws {
        let f = try await SessionFixture.ready()
        f.app.resume()
        let old = try await f.next("get_state")
        f.app.draft = "ask"
        XCTAssertTrue(f.app.send())
        f.app.chooseModel(f.option("b"))
        await f.reply(try await f.next("set_model"))
        let current = try await f.next("get_state")
        await f.state(current, model: "b", thinking: "off")
        await f.state(old, model: "a", thinking: "high")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        XCTAssertEqual(f.app.thinking, "off")
    }

    func testThinkingAndModelChangesAreAppliedInTapOrder() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let modelChange = try await f.next("set_model")
        f.app.setThinking("low")
        f.app.resume()
        let stale = try await f.next("get_state")
        await f.state(stale, model: "a", thinking: "high")
        XCTAssertEqual(f.app.thinking, "low")
        XCTAssertFalse(f.socket.commands.contains { $0["type"] as? String == "set_thinking_level" })
        await f.reply(modelChange)
        let effort = try await f.next("set_thinking_level")
        XCTAssertEqual(effort["level"] as? String, "low")
        await f.reply(effort)
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        XCTAssertEqual(f.app.thinking, "low")
    }

    func testReconnectWaitsForAMatchedSettingBarrierOrTheOriginalReply() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let change = try await f.next("set_model")
        f.app.chooseModel(f.option("c"))
        f.app.reconnect()
        await f.handshake()
        let stale = try await f.next("get_state")
        let expected = try XCTUnwrap(change["id"] as? String)
        XCTAssertEqual(stale["afterSettingChangeId"] as? String, expected)
        await f.state(stale, model: "a")
        XCTAssertFalse(f.app.canSend, "A fresh socket alone cannot prove a delayed Mac write has completed")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        f.app.resume()
        let barrier = try await f.next("get_state")
        await f.reply(barrier, data: ["isStreaming": false, "messageCount": 0, "model": ["provider": "fixture", "id": "a"], "settingBarrierId": expected])
        XCTAssertEqual(f.app.selectedModel, "fixture/a")
        XCTAssertTrue(f.app.canSend)
        XCTAssertNil(f.app.errorMessage)
        XCTAssertFalse(f.socket.commands.contains { $0["type"] as? String == "set_model" }, "Never replay cancelled or uncertain settings")
    }

    func testSessionPickedDuringSettingRecoveryLoadsBeforePrompt() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let change = try await f.next("set_model")
        await f.client.handle(["type": "status", "state": "unknown"])
        await f.client.handle(["type": "status", "state": "idle"])
        let state = try await f.next("get_state")
        let path = "/fixture/another.jsonl"
        f.app.switchSession(path)
        f.app.draft = "for the newly selected conversation"
        await f.reply(state, data: ["isStreaming": false, "messageCount": 0, "model": ["provider": "fixture", "id": "b"], "settingBarrierId": try XCTUnwrap(change["id"] as? String)])
        XCTAssertFalse(f.app.canSend)
        XCTAssertFalse(f.app.send())
        let open = try await f.next("switch_session")
        XCTAssertEqual(open["sessionPath"] as? String, path)
        await f.reply(open)
        XCTAssertFalse(f.app.canSend)
        let history = try await f.next("session_history")
        await f.reply(history, data: ["sessionPath": path, "messages": []])
        XCTAssertEqual(f.app.selectedSessionPath, path)
        XCTAssertTrue(f.app.canSend)
        XCTAssertEqual(f.app.draft, "for the newly selected conversation")
    }

    func testAuthenticatedReplyRecoversLegacyGatewayWithoutStatus() async throws {
        let f = try await SessionFixture.ready()
        await f.client.handle(["type": "status", "state": "unknown"])
        await f.client.handle(["type": "event", "sealed": "invalid fixture"])
        XCTAssertEqual(f.app.connection, .error)
        await f.client.handle(["type": "event", "sealed": f.socket.key!.seal(["type": "agent_start"])!])
        XCTAssertTrue(f.app.isConnected)
        XCTAssertNil(f.app.errorMessage)
        await f.client.handle(["type": "error", "message": "图片超过限制"])
        XCTAssertTrue(f.app.isConnected)
        XCTAssertEqual(f.app.errorMessage, "图片超过限制")
    }

    func testHealthyGatewayClearsOfflineAndRepairBannerOnSameSocket() async throws {
        let f = try await SessionFixture.ready()
        for fault: [String: Any] in [["type": "status", "state": "unknown"],
                                     ["type": "error", "message": "端到端密钥协商失败，请重新配对"]] {
            await f.client.handle(fault)
            await f.drain()
            XCTAssertNotNil(f.app.errorMessage)
            XCTAssertEqual(f.app.connection, .error)
            await f.client.handle(["type": "status", "state": "idle"])
            await f.drain()
            XCTAssertNil(f.client.lastError)
            XCTAssertNil(f.app.errorMessage)
            XCTAssertFalse(f.app.needsRepair)
            XCTAssertEqual(f.app.connection, .paired)
        }
    }

    func testRecoveryKeepsActionFailureButClearsDisconnectedSendHint() async throws {
        let f = try await SessionFixture.ready()
        f.app.chooseModel(f.option("b"))
        let change = try await f.next("set_model")
        await f.reply(change, error: "Model unavailable")
        await f.client.handle(["type": "status", "state": "unknown"])
        await f.client.handle(["type": "status", "state": "idle"])
        await f.drain()
        XCTAssertEqual(f.app.errorMessage, "Model unavailable")
        f.app.clearError()
        await f.client.handle(["type": "status", "state": "unknown"])
        await f.drain()
        f.app.draft = "draft"
        XCTAssertFalse(f.app.send())
        await f.handshake()
        await f.drain()
        XCTAssertNil(f.app.errorMessage)
        XCTAssertEqual(f.app.draft, "draft")
    }
}

@MainActor
private final class SessionFixture {
    let socket = CommandSocket()
    let client: RelayClient
    let app: AppModel
    let token = String(repeating: "a", count: 64)

    init() {
        let socket = socket
        var record: String?
        let store = PairingStore(read: { record }, write: { record = $0; return true }, clear: { record = nil })
        client = RelayClient(endpoint: nil, store: store, makeSocket: { _ in socket })
        app = AppModel(client: client)
    }

    static func ready() async throws -> SessionFixture {
        let f = SessionFixture()
        await f.drain()
        let pub = f.socket.gateway.publicKey.rawRepresentation.base64UrlEncoded
        f.app.pair(token: "https://test.invalid/pi/pair#" + String(repeating: "b", count: 32) + "." + pub)
        await f.handshake()
        await f.drain()
        var initial = try await f.next("get_state")
        while let i = f.socket.commands.firstIndex(where: { $0["type"] as? String == "get_state" }) {
            initial = f.socket.commands.remove(at: i)
        }
        await f.state(initial, model: "a")
        XCTAssertEqual(f.app.selectedModel, "fixture/a")
        return f
    }

    func option(_ id: String) -> ModelOption { ModelOption(provider: "fixture", modelId: id) }

    func handshake() async {
        await client.handle(["type": "paired", "deviceToken": token])
    }

    func next(_ type: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let index = socket.commands.firstIndex(where: { $0["type"] as? String == type }) {
                return socket.commands.remove(at: index)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Missing outgoing \(type)", code: 1)
    }

    func reply(_ command: [String: Any], data: [String: Any] = [:], error: String? = nil) async {
        var response: [String: Any] = ["id": command["id"] as Any, "success": error == nil, "data": data]
        if let error { response["error"] = error }
        await client.handle(["type": "rpc_response", "sealed": socket.key!.seal(response)!])
    }

    func state(_ command: [String: Any], model: String, thinking: String = "high") async {
        await reply(command, data: ["isStreaming": false, "messageCount": 0, "model": ["provider": "fixture", "id": model], "thinkingLevel": thinking])
    }

    func drain() async { try? await Task.sleep(for: .milliseconds(30)) }
}

@MainActor
private final class CommandSocket: RelaySocket {
    let gateway = Curve25519.KeyAgreement.PrivateKey()
    var key: E2EKey?
    var commands: [[String: Any]] = []
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message,
              let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if frame["type"] as? String == "pair_pub", let pub = frame["pub"] as? String {
            key = E2EKey(privateKeyBase64Url: gateway.rawRepresentation.base64UrlEncoded, gatewayPublicKey: pub)
        }
        if let sealed = frame["sealed"] as? String, let command = key?.open(sealed)?["command"] as? [String: Any] {
            commands.append(command)
        }
    }
}

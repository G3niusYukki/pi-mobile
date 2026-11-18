import CryptoKit
import XCTest
@testable import PiMobileCore
@testable import PiMobile

/// Exercise the production handshake, encrypted wire commands, and app callbacks in memory.
@MainActor
final class ModelConnectionTests: XCTestCase {
    func testStreamingDuringAStateRefreshKeepsChatClearAndAcceptsTheLateReply() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
        f.app.draft = "a slow answer"
        XCTAssertTrue(f.app.send())
        await f.reply(try await f.next("prompt"), data: ["disposition": "started"])
        await f.event(["type": "agent_start"])
        f.app.resume()
        let snapshot = try await f.next("get_state")
        await f.delta("still speaking")
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(f.app.messages.last?.text, "still speaking")
        XCTAssertEqual(f.app.connection, .running)
        XCTAssertNil(f.app.errorMessage, "A delayed background snapshot must not interrupt a live reply")
        await f.state(snapshot, model: "b")
        XCTAssertEqual(f.app.selectedModel, "fixture/b", "The correlated late reply still owns the settings readback")
        XCTAssertEqual(f.app.connection, .running, "The older idle snapshot must not settle a newer delta")
    }

    func testSilentStateTimeoutClearsOnlyWhenPiTrafficResumes() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
        f.app.resume()
        let snapshot = try await f.next("get_state")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")
        await f.client.handle(["type": "event", "sealed": "invalid fixture"])
        XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")

        await f.delta("new progress")
        XCTAssertNil(f.app.errorMessage)
        XCTAssertEqual(f.app.messages.last?.text, "new progress")
        await f.state(snapshot, model: "b")
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
    }

    func testStateTimeoutDoesNotReplaceRejectedStopOrHideGatewayLoss() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
        f.app.stop()
        await f.reply(try await f.next("abort"), error: "Fixture stop rejected")
        f.app.resume()
        let snapshot = try await f.next("get_state")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(f.app.errorMessage, "Fixture stop rejected")
        await f.state(snapshot, model: "b")
        XCTAssertEqual(f.app.errorMessage, "Fixture stop rejected")
        await f.client.handle(["type": "status", "state": "unknown"])
        XCTAssertEqual(f.app.errorMessage, "Mac gateway 离线")
        await f.client.handle(["type": "status", "state": "idle"])
        XCTAssertEqual(f.app.errorMessage, "Fixture stop rejected")
    }

    func testLateStateBarrierRecoversAnUnacknowledgedSessionSwitch() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
        let path = "/fixture/recovered.jsonl"
        f.app.switchSession(path)
        let change = try await f.next("switch_session")
        let changeID = try XCTUnwrap(change["id"] as? String)
        await f.client.handle(["type": "status", "state": "unknown"])
        await f.client.handle(["type": "status", "state": "idle"])
        let snapshot = try await f.next("get_state")
        XCTAssertEqual(snapshot["afterSessionChangeId"] as? String, changeID)
        await f.reply(try await f.next("get_available_models"), data: ["models": []])
        await f.reply(try await f.next("session_catalog"), data: ["sessions": []])
        try await Task.sleep(for: .milliseconds(600))
        await f.delta("activity while the switch is pending")
        XCTAssertFalse(f.app.canSend, "Progress alone cannot acknowledge the session switch")

        await f.reply(snapshot, data: ["isStreaming": false, "messageCount": 0, "sessionFile": path,
                                       "sessionBarrier": true, "sessionBarrierId": changeID])
        XCTAssertTrue(f.app.canSend)
        XCTAssertEqual(f.app.selectedSessionPath, path)
        XCTAssertNil(f.app.errorMessage)
    }

    func testSilentNewSocketShowsStateTimeoutAndKeepsThePreviousReplyAndTool() async throws {
        let path = "/fixture/reconnect.jsonl"
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500), path: path)
        await f.delta("Partial reply")
        await f.event(["type": "tool_execution_update", "toolCallId": "call-1", "toolName": "read",
                       "partialResult": ["content": "Partial tool output"]])
        let assistant = try XCTUnwrap(f.app.messages.first { $0.role == .assistant })
        let tool = try XCTUnwrap(f.app.messages.first { $0.role == .tool })
        XCTAssertEqual(f.app.connection, .running)
        let oldSocket = f.socket
        f.app.reconnect()
        XCTAssertFalse(f.socket === oldSocket)
        await f.handshake()
        let state = try await f.next("get_state")
        let history = try await f.next("session_history")
        await f.reply(try await f.next("get_available_models"), data: ["models": []])
        await f.reply(try await f.next("session_catalog"), data: ["sessions": []])
        // The saved file can lag the live stream. No new Pi event follows this handshake.
        await f.history(history, path: path, items: [f.savedQuestion])
        XCTAssertEqual(f.app.connection, .paired)
        XCTAssertEqual(f.app.messages.first { $0.id == assistant.id }?.text, "Partial reply")
        XCTAssertEqual(f.app.messages.first { $0.id == tool.id }?.toolStatus, .unconfirmed)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")
        await f.state(state, model: "b", path: path)
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
        XCTAssertNil(f.app.errorMessage)
        await f.history(try await f.next("session_history"), path: path, items: [f.savedQuestion,
            ["id": "answer", "role": "assistant", "text": "Partial reply completed"],
            ["id": "tool", "role": "tool", "toolTitle": "read", "toolCallId": "call-1", "text": "Complete output"]])
        XCTAssertEqual(f.app.messages.first { $0.id == assistant.id }?.text, "Partial reply completed")
        XCTAssertEqual(f.app.messages.first { $0.id == tool.id }?.text, "Complete output")
    }

    func testIdleStateBeforeLaggingHistoryPreservesTheInterruptedTurnOnTheSameBranch() async throws {
        let path = "/fixture/idle-before-history.jsonl"
        let f = try await SessionFixture.ready(path: path)
        f.app.draft = "Local question"
        XCTAssertTrue(f.app.send())
        await f.reply(try await f.next("prompt"), data: ["disposition": "started"])
        await f.delta("Reply so far")
        await f.event(["type": "tool_execution_start", "toolCallId": "call", "toolName": "read"])
        let ids = f.app.messages.map(\.id)
        f.app.reconnect()
        await f.handshake()
        let state = try await f.next("get_state")
        let history = try await f.next("session_history")
        await f.state(state, model: "a", path: path)
        await f.history(history, path: path, items: [f.savedQuestion])
        XCTAssertEqual(f.app.connection, .paired)
        XCTAssertEqual(f.app.messages.map(\.id), ids)
        XCTAssertEqual(f.app.messages.last?.toolStatus, .unconfirmed)
        f.app.resume()
        await f.history(try await f.next("session_history"), path: path, items: [
            ["id": "other", "role": "user", "text": "Another branch"]])
        XCTAssertEqual(f.app.messages.map(\.text), ["Another branch"])
    }

    func testCurrentSocketCanConfirmASlowRunWithoutAdditionalDeltas() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
        await f.event(["type": "run_phase", "phase": "thinking"])
        f.app.resume()
        let snapshot = try await f.next("get_state")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(f.app.connection, .running)
        XCTAssertNil(f.app.errorMessage)
        await f.state(snapshot, model: "b")
        XCTAssertEqual(f.app.connection, .paired)
        XCTAssertEqual(f.app.selectedModel, "fixture/b")
    }

    func testKnownHistoryRefreshKeepsItsLateReplyWhilePiStreams() async throws {
        let path = "/fixture/background.jsonl"
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500), path: path)
        f.app.resume()
        let state = try await f.next("get_state")
        let history = try await f.next("session_history")
        await f.state(state, model: "a", path: path)
        await f.delta("Still working")
        let assistant = try XCTUnwrap(f.app.messages.last)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(f.app.errorMessage)
        XCTAssertFalse(f.app.isLoadingHistory, "A refresh of an already visible transcript must leave session actions available")
        await f.history(history, path: path, items: [f.savedQuestion,
            ["id": "new", "role": "user", "text": "Arrived in history"]])
        XCTAssertTrue(f.app.messages.contains { $0.sourceID == "new" })
        XCTAssertEqual(f.app.messages.last?.id, assistant.id)
        XCTAssertEqual(f.app.messages.last?.text, "Still working")
        XCTAssertNil(f.app.errorMessage)
    }

    func testExplicitSwitchKeepsHistoryTimeoutAndRealReadFailureVisible() async throws {
        let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500), path: "/fixture/previous.jsonl")
        let path = "/fixture/destination.jsonl"
        f.app.switchSession(path)
        await f.reply(try await f.next("switch_session"))
        let history = try await f.next("session_history")
        await f.reply(try await f.next("session_catalog"), data: ["sessions": []])
        XCTAssertTrue(f.app.isLoadingHistory)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(f.app.errorMessage, "加载历史失败：等待响应超时")
        XCTAssertFalse(f.app.isLoadingHistory)
        XCTAssertFalse(f.app.canSend)
        await f.reply(history, error: "Fixture history is unreadable")
        XCTAssertEqual(f.app.errorMessage, "Fixture history is unreadable")
        XCTAssertEqual(f.app.selectedSessionPath, "/fixture/previous.jsonl")
    }

    func testNativePromptAckClearsOnlyStateTimeoutAndKeepsSettingsReadback() async throws {
        for disposition in ["queued", "handled"] {
            let f = try await SessionFixture.ready(rpcTimeout: .milliseconds(500))
            f.app.resume()
            let snapshot = try await f.next("get_state")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")
            f.app.loadSessions()
            await f.reply(try await f.next("session_catalog"), data: ["sessions": []])
            XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")
            f.app.draft = "fixture prompt"
            XCTAssertTrue(f.app.send())
            let prompt = try await f.next("prompt")
            XCTAssertEqual(f.app.errorMessage, "获取状态失败：等待响应超时")
            await f.reply(prompt, data: ["disposition": disposition])
            XCTAssertNil(f.app.errorMessage, disposition)
            await f.state(snapshot, model: "b")
            XCTAssertEqual(f.app.selectedModel, "fixture/b")
        }
    }

    func testNativeAckKeepsAnExplicitStateFailure() async throws {
        let f = try await SessionFixture.ready()
        f.app.resume()
        await f.reply(try await f.next("get_state"), error: "Fixture state rejected")
        f.app.draft = "fixture prompt"
        XCTAssertTrue(f.app.send())
        await f.reply(try await f.next("prompt"), data: ["disposition": "handled"])
        XCTAssertEqual(f.app.errorMessage, "Fixture state rejected")
    }

    func testProductionSocketCanReceiveAnEncryptedHistoryFrameUpToTheRelayLimit() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "wss://test.invalid/pi/client")))
        let socket = RelayClient.webSocket(for: request)
        defer { socket.cancel() }
        XCTAssertEqual(socket.maximumMessageSize, 12 * 1024 * 1024)
    }

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
    private let gateway: FixtureGateway
    var socket: CommandSocket { gateway.currentSocket! }
    let client: RelayClient
    let app: AppModel
    let token = String(repeating: "a", count: 64)

    init(rpcTimeout: Duration) {
        let gateway = FixtureGateway()
        self.gateway = gateway
        var record: String?
        let store = PairingStore(read: { record }, write: { record = $0; return true }, clear: { record = nil })
        client = RelayClient(endpoint: nil, store: store, makeSocket: { _ in gateway.openSocket() })
        app = AppModel(client: client, rpcTimeout: rpcTimeout)
    }

    static func ready(rpcTimeout: Duration = .seconds(15), path: String? = nil) async throws -> SessionFixture {
        let f = SessionFixture(rpcTimeout: rpcTimeout)
        await f.drain()
        let pub = f.gateway.privateKey.publicKey.rawRepresentation.base64UrlEncoded
        f.app.pair(token: "https://test.invalid/pi/pair#" + String(repeating: "b", count: 32) + "." + pub)
        await f.handshake()
        await f.drain()
        var initial = try await f.next("get_state")
        while let i = f.socket.commands.firstIndex(where: { $0["type"] as? String == "get_state" }) {
            initial = f.socket.commands.remove(at: i)
        }
        await f.state(initial, model: "a", path: path)
        if let path {
            await f.history(try await f.next("session_history"), path: path, items: [f.savedQuestion])
        }
        await f.reply(try await f.next("get_available_models"), data: ["models": []])
        await f.reply(try await f.next("session_catalog"), data: ["sessions": []])
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

    func event(_ body: [String: Any]) async {
        await client.handle(["type": "event", "sealed": socket.key!.seal(body)!])
    }

    func delta(_ text: String) async {
        await event(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": text]])
    }

    var savedQuestion: [String: Any] { ["id": "saved-question", "role": "user", "text": "Saved question"] }

    func history(_ command: [String: Any], path: String, items: [[String: Any]]) async {
        await reply(command, data: ["sessionPath": path, "messages": items])
    }

    func state(_ command: [String: Any], model: String, thinking: String = "high", path: String? = nil) async {
        var data: [String: Any] = ["isStreaming": false, "messageCount": path == nil ? 0 : 1,
                                   "model": ["provider": "fixture", "id": model], "thinkingLevel": thinking]
        if let path { data["sessionFile"] = path }
        await reply(command, data: data)
    }

    func drain() async { try? await Task.sleep(for: .milliseconds(30)) }
}

@MainActor
private final class FixtureGateway {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private(set) var currentSocket: CommandSocket?

    func openSocket() -> CommandSocket {
        let socket = CommandSocket(gateway: privateKey)
        currentSocket = socket
        return socket
    }
}

@MainActor
private final class CommandSocket: RelaySocket {
    let gateway: Curve25519.KeyAgreement.PrivateKey
    init(gateway: Curve25519.KeyAgreement.PrivateKey) { self.gateway = gateway }
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

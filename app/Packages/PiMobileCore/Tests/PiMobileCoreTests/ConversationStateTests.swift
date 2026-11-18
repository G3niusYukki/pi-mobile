import XCTest
@testable import PiMobileCore

final class ConversationStateTests: XCTestCase {
    func testOfflinePromptDoesNotCreateSentMessages() {
        var state = ConversationState()
        XCTAssertNil(state.preparePrompt(id: "p1", text: "keep this draft", connected: false))
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertFalse(state.isRunning)
    }

    func testBusyPromptUsesSteeringWithoutReplacingActiveAssistant() throws {
        var state = ConversationState()
        let first = try XCTUnwrap(state.preparePrompt(id: "p1", text: "first", connected: true))
        XCTAssertEqual(first["streamingBehavior"] as? String, "steer")
        state.applyEvent(textDelta("answer"))
        let active = try XCTUnwrap(state.streamingID)
        let second = try XCTUnwrap(state.preparePrompt(id: "p2", text: "also this", connected: true))
        XCTAssertEqual(second["streamingBehavior"] as? String, "steer")
        XCTAssertEqual(state.streamingID, active)
        state.applyEvent(textDelta(" continues"))
        XCTAssertEqual(state.messages.first(where: { $0.id == active })?.text, "answer continues")
        XCTAssertEqual(state.messages.filter { $0.role == .assistant }.count, 1)
    }

    func testRejectedSteeringKeepsExistingRunAndReturnsDraft() {
        var state = ConversationState()
        _ = state.preparePrompt(id: "p1", text: "first", connected: true)
        state.applyEvent(textDelta("working"))
        let active = state.streamingID
        _ = state.preparePrompt(id: "p2", text: "retry me", connected: true)
        XCTAssertEqual(state.resolvePrompt(id: "p2", success: false), "retry me")
        XCTAssertEqual(state.streamingID, active)
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.messages.contains { $0.text == "retry me" })
    }

    func testSwitchWaitsForAckAndHistoryBeforeReplacingConversation() {
        var state = loadedState()
        let originalID = state.conversationID
        let originalMessages = state.messages
        XCTAssertTrue(state.beginSessionChange(id: "switch", path: "/b"))
        XCTAssertTrue(state.isLoadingHistory)
        XCTAssertEqual(state.sessionPath, "/a")
        XCTAssertEqual(state.messages, originalMessages)
        XCTAssertFalse(state.beginSessionChange(id: "overlap", path: "/c"))
        XCTAssertTrue(state.resolveSessionChange(id: "switch", success: true))
        XCTAssertEqual(state.sessionPath, "/a")
        XCTAssertFalse(state.canSend)
        state.beginHistory(id: "history", path: "/b")
        XCTAssertTrue(state.receiveHistory(id: "history", path: "/b", items: [item("b1", "user", "B")]))
        XCTAssertEqual(state.sessionPath, "/b")
        XCTAssertNotEqual(state.conversationID, originalID)
        XCTAssertEqual(state.messages.map(\.text), ["B"])
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertTrue(state.canSend)
    }

    func testCancelledOrFailedSwitchRetainsConversationAndStopsLoading() {
        for cancelled in [false, true] {
            var state = loadedState()
            let before = state.messages
            let originalID = state.conversationID
            _ = state.beginSessionChange(id: "switch", path: "/b")
            XCTAssertFalse(state.resolveSessionChange(id: "switch", success: cancelled, cancelled: cancelled))
            XCTAssertFalse(state.isLoadingHistory)
            XCTAssertEqual(state.messages, before)
            XCTAssertEqual(state.sessionPath, "/a")
            XCTAssertEqual(state.conversationID, originalID)
            XCTAssertFalse(state.canSend)
            state.beginStateRequest(id: "after-cancel")
            XCTAssertTrue(state.receiveState(id: "after-cancel", path: "/a", running: false))
            XCTAssertTrue(state.canSend)
        }
    }

    func testStaleHistoryCannotReplaceNewerRequestOrStopItsSpinner() {
        var state = loadedState()
        state.beginHistory(id: "old", path: "/a")
        _ = state.beginSessionChange(id: "switch", path: "/b")
        _ = state.resolveSessionChange(id: "switch", success: true)
        state.beginHistory(id: "new", path: "/b")
        XCTAssertFalse(state.receiveHistory(id: "old", path: "/a", items: []))
        XCTAssertTrue(state.isLoadingHistory)
        XCTAssertFalse(state.receiveHistory(id: "new", path: "/a", items: []))
        XCTAssertTrue(state.isLoadingHistory)
        XCTAssertTrue(state.receiveHistory(id: "new", path: "/b", items: [item("b", "user", "B")]))
        XCTAssertEqual(state.messages.map(\.text), ["B"])
    }

    func testHistoryFailurePreservesPriorConversationAndCannotSendToHiddenTarget() {
        var state = loadedState()
        let originalID = state.conversationID
        _ = state.beginSessionChange(id: "switch", path: "/b")
        _ = state.resolveSessionChange(id: "switch", success: true)
        state.beginHistory(id: "history", path: "/b")
        XCTAssertTrue(state.failRequest(id: "history"))
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertEqual(state.sessionPath, "/a")
        XCTAssertEqual(state.conversationID, originalID)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        XCTAssertNil(state.preparePrompt(id: "p", text: "wrong destination", connected: true))
    }

    func testRepeatedHistoryKeepsIdentityIncludingIdenticalMessages() {
        var state = ConversationState()
        let items = [item("one", "user", "same"), item("two", "user", "same")]
        state.beginHistory(id: "h1", path: "/a")
        _ = state.receiveHistory(id: "h1", path: "/a", items: items)
        let ids = state.messages.map(\.id)
        let conversationID = state.conversationID
        state.beginHistory(id: "h2", path: "/a")
        _ = state.receiveHistory(id: "h2", path: "/a", items: items)
        XCTAssertEqual(state.messages.map(\.id), ids)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(state.conversationID, conversationID)
    }

    func testHistoryRefreshKeepsOptimisticIDsAndStreamingTail() throws {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "question", connected: true)
        state.applyEvent(textDelta("partial"))
        let userID = try XCTUnwrap(state.messages.first { $0.text == "question" }?.id)
        let assistantID = try XCTUnwrap(state.streamingID)
        state.beginHistory(id: "h", path: "/a")
        state.applyEvent(textDelta(" newer"))
        _ = state.receiveHistory(id: "h", path: "/a", items: [item("a", "user", "A"), item("q", "user", "question")])
        XCTAssertEqual(state.messages.first { $0.text == "question" }?.id, userID)
        XCTAssertEqual(state.streamingID, assistantID)
        XCTAssertEqual(state.messages.first { $0.id == assistantID }?.text, "partial newer")
    }

    func testStateFromBeforePromptOrSwitchCannotSettleCurrentRun() {
        var state = loadedState()
        state.beginStateRequest(id: "old")
        _ = state.preparePrompt(id: "p", text: "question", connected: true)
        XCTAssertFalse(state.receiveState(id: "old", path: "/a", running: false))
        XCTAssertTrue(state.isRunning)
        state.beginStateRequest(id: "before-switch")
        _ = state.beginSessionChange(id: "switch", path: "/b")
        XCTAssertFalse(state.receiveState(id: "before-switch", path: "/a", running: false))
    }

    func testAgentEndFinishesMessageButSettledFinishesRun() {
        var state = ConversationState()
        _ = state.preparePrompt(id: "p", text: "question", connected: true)
        state.applyEvent(textDelta("done"))
        state.applyEvent(["type": "agent_end"])
        XCTAssertNil(state.streamingID)
        XCTAssertFalse(state.messages.contains { $0.streaming })
        XCTAssertTrue(state.isRunning)
        state.applyEvent(["type": "agent_settled"])
        XCTAssertFalse(state.isRunning)
    }

    func testHandledPromptDoesNotLeaveAnEmptyRunningReply() {
        var state = ConversationState()
        _ = state.preparePrompt(id: "p", text: "/extension-command", connected: true)
        _ = state.resolvePrompt(id: "p", success: true, disposition: "handled")
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.streamingID)
        XCTAssertEqual(state.messages.count, 1)
    }

    func testStateCanRecoverSessionPathWithoutOverwritingNewerStream() {
        var state = ConversationState()
        state.beginStateRequest(id: "state")
        state.applyEvent(textDelta("live"))
        XCTAssertTrue(state.receiveState(id: "state", path: "/a", running: false))
        XCTAssertEqual(state.sessionPath, "/a")
        XCTAssertTrue(state.isRunning)
        XCTAssertNotNil(state.streamingID)
    }

    func testUnknownSwitchRequiresItsLateAckBeforeLoadingOrSending() {
        var state = loadedState()
        let originalID = state.conversationID
        _ = state.beginSessionChange(id: "switch", path: "/b")
        XCTAssertTrue(state.failRequest(id: "switch", outcomeUnknown: true))
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        state.beginStateRequest(id: "state")
        XCTAssertFalse(state.receiveState(id: "state", path: "/a", running: false))
        XCTAssertFalse(state.canSend)
        XCTAssertFalse(state.beginSessionChange(id: "overlap", path: "/c"))
        XCTAssertNil(state.preparePrompt(id: "p", text: "wrong destination", connected: true))
        XCTAssertEqual(state.conversationID, originalID)
        XCTAssertEqual(state.pendingChange?.id, "switch")
        XCTAssertTrue(state.resolveSessionChange(id: "switch", success: true))
        XCTAssertFalse(state.canSend)
        state.beginHistory(id: "history", path: "/b")
        XCTAssertTrue(state.receiveHistory(id: "history", path: "/b", items: [item("b", "user", "B")]))
        XCTAssertEqual(state.sessionPath, "/b")
        XCTAssertTrue(state.canSend)
    }

    func testUnknownSwitchSurvivesDisconnectAndLateCancellationRestoresPriorSession() {
        var state = loadedState()
        let before = state.messages
        let originalID = state.conversationID
        _ = state.beginSessionChange(id: "switch", path: "/b")
        state.disconnected()
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertEqual(state.pendingChange?.id, "switch")
        state.beginStateRequest(id: "after-reconnect")
        XCTAssertFalse(state.receiveState(id: "after-reconnect", path: "/a", running: false))
        XCTAssertFalse(state.canSend)
        XCTAssertFalse(state.resolveSessionChange(id: "switch", success: true, cancelled: true))
        XCTAssertFalse(state.canSend)
        state.beginStateRequest(id: "after-cancel")
        XCTAssertTrue(state.receiveState(id: "after-cancel", path: "/a", running: false))
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.messages, before)
        XCTAssertEqual(state.conversationID, originalID)
    }

    func testSteeredHistoryReorderingKeepsEachLiveMessageExactlyOnce() throws {
        var state = loadedState()
        _ = state.preparePrompt(id: "p1", text: "first", connected: true)
        state.applyEvent(textDelta("answer"))
        let assistantID = try XCTUnwrap(state.streamingID)
        _ = state.preparePrompt(id: "p2", text: "second", connected: true)
        let firstID = try XCTUnwrap(state.messages.first { $0.text == "first" }?.id)
        let secondID = try XCTUnwrap(state.messages.first { $0.text == "second" }?.id)
        state.beginHistory(id: "reordered", path: "/a")
        _ = state.receiveHistory(id: "reordered", path: "/a", items: [
            item("a", "user", "A"), item("one", "user", "first"),
            item("two", "user", "second"), item("answer", "assistant", "answer")
        ])
        XCTAssertEqual(state.messages.map(\.text), ["A", "first", "second", "answer"])
        XCTAssertEqual(state.messages.first { $0.text == "first" }?.id, firstID)
        XCTAssertEqual(state.messages.first { $0.text == "second" }?.id, secondID)
        XCTAssertEqual(state.messages.last?.id, assistantID)
        XCTAssertEqual(Set(state.messages.map(\.id)).count, state.messages.count)
        state.applyEvent(textDelta(" newer"))
        XCTAssertEqual(state.messages.last?.text, "answer newer")
    }

    func testNewSessionCommitsOnlyOnAckAndPathBindingKeepsIdentity() {
        var state = loadedState()
        let oldID = state.conversationID
        _ = state.beginSessionChange(id: "new", path: nil)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        _ = state.resolveSessionChange(id: "new", success: true)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertNil(state.sessionPath)
        XCTAssertNotEqual(state.conversationID, oldID)
        let newID = state.conversationID
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/new-not-yet-persisted", running: false)
        XCTAssertEqual(state.conversationID, newID)
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertTrue(state.canSend)
    }

    func testDisconnectEndsLoadingAndReconnectionKeepsConversationIdentity() {
        var state = loadedState()
        let originalID = state.conversationID
        let messageID = state.messages[0].id
        state.beginHistory(id: "history", path: "/a")
        state.disconnected()
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertFalse(state.receiveHistory(id: "history", path: "/a", items: []))
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/a", running: false)
        state.beginHistory(id: "fresh", path: "/a")
        _ = state.receiveHistory(id: "fresh", path: "/a", items: [item("a", "user", "A")])
        XCTAssertEqual(state.conversationID, originalID)
        XCTAssertEqual(state.messages[0].id, messageID)
    }

    func testReturningToPriorSessionUsesItsStableHistoryIDs() {
        var state = loadedState()
        let id = state.messages[0].id
        _ = state.beginSessionChange(id: "b", path: "/b")
        _ = state.resolveSessionChange(id: "b", success: true)
        state.beginHistory(id: "hb", path: "/b")
        _ = state.receiveHistory(id: "hb", path: "/b", items: [item("b", "user", "B")])
        _ = state.beginSessionChange(id: "a", path: "/a")
        _ = state.resolveSessionChange(id: "a", success: true)
        state.beginHistory(id: "ha", path: "/a")
        _ = state.receiveHistory(id: "ha", path: "/a", items: [item("a", "user", "A")])
        XCTAssertEqual(state.messages[0].id, id)
    }

    func testStateForAnotherSessionInvalidatesInFlightOldHistory() {
        var state = loadedState()
        state.beginHistory(id: "old-history", path: "/a")
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/b", running: false)
        XCTAssertFalse(state.receiveHistory(id: "old-history", path: "/a", items: []))
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        state.beginHistory(id: "new-history", path: "/b")
        XCTAssertTrue(state.receiveHistory(id: "new-history", path: "/b", items: [item("b", "user", "B")]))
        XCTAssertEqual(state.sessionPath, "/b")
    }

    func testToolLifecycleProducesOneCardWithFinalCopyableOutputPerCall() {
        var state = ConversationState()
        state.applyEvent(["type": "message_update", "assistantMessageEvent": ["type": "toolcall_start", "toolName": "bash"]])
        state.applyEvent(["type": "tool_execution_start", "toolCallId": "one", "toolName": "bash"])
        state.applyEvent(["type": "tool_execution_start", "toolCallId": "two", "toolName": "bash"])
        state.applyEvent(["type": "tool_execution_update", "toolCallId": "one", "toolName": "bash", "partialResult": ["content": [["type": "text", "text": "partial"]]]])
        XCTAssertEqual(state.messages.filter { $0.role == .tool }.count, 2)
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "two", "toolName": "bash", "result": ["content": [["type": "text", "text": "second result"]]]])
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "one", "toolName": "bash", "result": ["content": [["type": "text", "text": "complete output"]]]])
        XCTAssertEqual(state.messages.filter { $0.role == .tool }.map(\.text), ["complete output", "second result"])
    }

    func testToolHistoryReconcilesPartialByCallIDAcrossDisconnect() throws {
        var state = loadedState()
        state.applyEvent(["type": "agent_start"])
        state.applyEvent(["type": "tool_execution_start", "toolCallId": "t1", "toolName": "read"])
        state.applyEvent(["type": "tool_execution_update", "toolCallId": "t1", "toolName": "read", "partialResult": ["content": [["type": "text", "text": "partial"]]]])
        let toolID = try XCTUnwrap(state.messages.last?.id)
        state.disconnected()
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/a", running: true)
        state.beginHistory(id: "history", path: "/a")
        _ = state.receiveHistory(id: "history", path: "/a", items: [
            item("a", "user", "A"),
            ["id": "persisted-t1", "role": "tool", "toolTitle": "read", "toolCallId": "t1", "text": "complete output"]
        ])
        XCTAssertEqual(state.messages.filter { $0.role == .tool }.count, 1)
        XCTAssertEqual(state.messages.last?.id, toolID)
        XCTAssertEqual(state.messages.last?.text, "complete output")
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "t1", "toolName": "read", "result": ["content": [["type": "text", "text": "complete output"]]]])
        XCTAssertEqual(state.messages.filter { $0.role == .tool }.count, 1)
    }

    func testCancelledSwitchReconcilesEventsMissedWhileTransitionWasPending() {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "question", connected: true)
        _ = state.resolvePrompt(id: "p", success: true)
        state.applyEvent(textDelta("partial"))
        _ = state.beginSessionChange(id: "switch", path: "/b")
        state.applyEvent(["type": "agent_settled"])
        _ = state.resolveSessionChange(id: "switch", success: true, cancelled: true)
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertFalse(state.canSend)
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/a", running: false)
        state.beginHistory(id: "history", path: "/a")
        _ = state.receiveHistory(id: "history", path: "/a", items: [
            item("a", "user", "A"), item("q", "user", "question"), item("r", "assistant", "complete")
        ])
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A", "question", "complete"])
    }

    func testHistoryWindowKeepsLoadedPrefixWhileFullSnapshotCanReplaceBranch() {
        var state = ConversationState()
        let first = (0..<80).map { item("row-\($0)", "user", "message \($0)") }
        state.beginHistory(id: "first", path: "/a")
        _ = state.receiveHistory(id: "first", path: "/a", items: first)
        let originalIDs = state.messages.map(\.id)
        let latest = (2..<82).map { item("row-\($0)", "user", "message \($0)") }
        state.beginHistory(id: "latest", path: "/a")
        _ = state.receiveHistory(id: "latest", path: "/a", items: latest, hasEarlierMessages: true)
        XCTAssertEqual(state.messages.count, 82)
        XCTAssertEqual(Array(state.messages.prefix(80).map(\.id)), originalIDs)
        XCTAssertEqual(state.messages.last?.text, "message 81")
        state.beginHistory(id: "branch", path: "/a")
        _ = state.receiveHistory(id: "branch", path: "/a", items: [item("other", "user", "other branch")])
        XCTAssertEqual(state.messages.map(\.text), ["other branch"])
    }

    func testHistoryAnchorUsesLatestPersistedEntryBeforeOptimisticTail() {
        var state = loadedState()
        state.beginHistory(id: "latest", path: "/a")
        _ = state.receiveHistory(id: "latest", path: "/a", items: [
            item("a", "user", "A"), item("reply", "assistant", "persisted answer")
        ])
        _ = state.preparePrompt(id: "prompt", text: "not persisted yet", connected: true)
        state.applyEvent(textDelta("live reply"))
        XCTAssertEqual(state.historyAnchorID(for: "/a"), "reply")
        state.disconnected()
        XCTAssertEqual(state.historyAnchorID(for: "/a"), "reply")
    }

    func testHistoryAnchorAcceptsPersistedToolEntryWithoutLeakingAcrossSessions() {
        var state = loadedState()
        state.beginHistory(id: "tool-history", path: "/a")
        _ = state.receiveHistory(id: "tool-history", path: "/a", items: [
            item("a", "user", "A"),
            ["id": "tool-entry", "role": "tool", "toolTitle": "read", "toolCallId": "t1", "text": "output"]
        ])
        XCTAssertEqual(state.historyAnchorID(for: "/a"), "tool-entry")
        XCTAssertNil(state.historyAnchorID(for: "/b"))
        _ = state.beginSessionChange(id: "switch", path: "/b")
        _ = state.resolveSessionChange(id: "switch", success: true)
        XCTAssertNil(state.historyAnchorID(for: "/b"))
        state.beginHistory(id: "new-history", path: "/b")
        _ = state.receiveHistory(id: "new-history", path: "/b", items: [item("b", "user", "B")])
        XCTAssertEqual(state.historyAnchorID(for: "/b"), "b")
        XCTAssertNil(state.historyAnchorID(for: "/a"))
    }

    func testHistoryAnchorIsAbsentUntilCurrentSessionHasPersistedMessages() {
        var state = ConversationState()
        XCTAssertNil(state.historyAnchorID(for: "/a"))
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/a", running: false)
        _ = state.preparePrompt(id: "prompt", text: "not persisted yet", connected: true)
        state.applyEvent(textDelta("live reply"))
        XCTAssertNil(state.historyAnchorID(for: "/a"))
    }

    func testHistoryAnchorPreservesLoadedPrefixAfterMoreThanAWindowOfNewMessages() throws {
        var state = ConversationState()
        state.beginHistory(id: "first", path: "/a")
        _ = state.receiveHistory(id: "first", path: "/a", items: (0..<80).map {
            item("row-\($0)", "user", "message \($0)")
        })
        let originalIDs = state.messages.map(\.id)
        let conversationID = state.conversationID
        let anchor = try XCTUnwrap(state.historyAnchorID(for: "/a"))
        XCTAssertEqual(anchor, "row-79")
        state.disconnected()
        state.beginHistory(id: "resumed", path: "/a")
        XCTAssertTrue(state.receiveHistory(id: "resumed", path: "/a", items: (79..<180).map {
            item("row-\($0)", "user", "message \($0)")
        }, hasEarlierMessages: true))
        XCTAssertEqual(state.messages.map(\.sourceID), (0..<180).map { "row-\($0)" })
        XCTAssertEqual(Array(state.messages.prefix(80).map(\.id)), originalIDs)
        XCTAssertEqual(state.conversationID, conversationID)
        state.beginHistory(id: "branch", path: "/a")
        _ = state.receiveHistory(id: "branch", path: "/a", items: (200..<280).map {
            item("row-\($0)", "user", "message \($0)")
        }, hasEarlierMessages: true)
        XCTAssertEqual(state.messages.map(\.sourceID), (200..<280).map { "row-\($0)" })
    }

    func testSessionSwitchHookCanAskForApprovalWhileConversationIsBlocked() throws {
        var state = loadedState()
        _ = state.beginSessionChange(id: "switch", path: "/b")
        let approval = try XCTUnwrap(state.applyEvent([
            "type": "extension_ui_request", "id": "confirm-switch", "method": "confirm",
            "title": "Switch session?", "message": "Current session is still running"
        ]))
        XCTAssertEqual(approval.id, "confirm-switch")
        XCTAssertEqual(approval.method, "confirm")
        XCTAssertEqual(state.pendingChange?.id, "switch")
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
    }

    func testUnknownSwitchRecoversOnlyFromBarrierForItsOwnRequest() {
        var state = loadedState()
        let oldID = state.conversationID
        _ = state.beginSessionChange(id: "switch", path: "/b")
        _ = state.failRequest(id: "switch", outcomeUnknown: true)
        state.beginStateRequest(id: "recovery")
        XCTAssertFalse(state.receiveState(id: "recovery", path: "/a", running: false, sessionBarrier: true, sessionBarrierID: "another-switch"))
        XCTAssertFalse(state.canSend)
        XCTAssertTrue(state.receiveState(id: "recovery", path: "/a", running: false, sessionBarrier: true, sessionBarrierID: "switch"))
        XCTAssertNil(state.pendingChange)
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.conversationID, oldID)
        XCTAssertFalse(state.resolveSessionChange(id: "switch", success: true))
        XCTAssertEqual(state.sessionPath, "/a")
    }

    func testLostSwitchAckAfterDisconnectCanRecoverDestinationThroughBarrier() {
        var state = loadedState()
        _ = state.beginSessionChange(id: "switch", path: "/b")
        state.disconnected()
        state.beginStateRequest(id: "recovery")
        XCTAssertTrue(state.receiveState(id: "recovery", path: "/b", running: false, messageCount: 1, sessionBarrier: true, sessionBarrierID: "switch"))
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        state.beginHistory(id: "history", path: "/b")
        XCTAssertTrue(state.receiveHistory(id: "history", path: "/b", items: [item("b", "user", "B")]))
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.sessionPath, "/b")
    }

    func testLostNewSessionAckUsesBarrierEmptyStateWithoutReadingMissingFile() {
        var state = loadedState()
        let oldID = state.conversationID
        _ = state.beginSessionChange(id: "new", path: nil)
        state.disconnected()
        state.beginStateRequest(id: "recovery")
        XCTAssertTrue(state.receiveState(id: "recovery", path: "/future-path", running: false, messageCount: 0, sessionBarrier: true, sessionBarrierID: "new"))
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertNil(state.pendingHistoryID)
        XCTAssertTrue(state.canSend)
        XCTAssertNotEqual(state.conversationID, oldID)
    }

    func testNewSessionRequiresLateAckBeforeBindingEmptyState() {
        var state = loadedState()
        let oldID = state.conversationID
        _ = state.beginSessionChange(id: "new", path: nil)
        _ = state.failRequest(id: "new", outcomeUnknown: true)
        state.beginStateRequest(id: "too-early")
        XCTAssertFalse(state.receiveState(id: "too-early", path: "/new-file-not-created", running: false, messageCount: 0))
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.messages.map(\.text), ["A"])
        XCTAssertTrue(state.resolveSessionChange(id: "new", success: true))
        state.beginStateRequest(id: "state")
        XCTAssertTrue(state.receiveState(id: "state", path: "/new-file-not-created", running: false, messageCount: 0))
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.canSend)
        XCTAssertFalse(state.isLoadingHistory)
        XCTAssertEqual(state.sessionPath, "/new-file-not-created")
        XCTAssertNotEqual(state.conversationID, oldID)
    }

    func testLegacyPiSnapshotsAndDeltasProjectOnlyVisibleTextThroughHistory() throws {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "ask", connected: true)
        let id = try XCTUnwrap(state.streamingID)
        let hidden = ["type": "thinking", "thinking": "private thought", "thinkingSignature": "private signature"]
        let literal = "  思考：<think>literal example</think>\n"
        let thinking: [String: Any] = ["role": "assistant", "content": [hidden]]
        state.applyEvent(["type": "message_update", "message": thinking, "assistantMessageEvent":
            ["type": "thinking_delta", "delta": "private thought", "partial": thinking]])
        XCTAssertEqual(state.messages.last?.text, "")
        let snapshot: [String: Any] = ["role": "assistant", "content": [hidden, ["type": "text", "text": literal]]]
        state.applyEvent(["type": "message_update", "assistantMessageEvent":
            ["type": "text_delta", "contentIndex": 1, "delta": "example</think>\n", "partial": snapshot]])
        XCTAssertEqual(state.messages.last?.text, literal)
        state.applyEvent(["type": "message_end", "message": snapshot])
        state.applyEvent(["type": "agent_end", "messages": [snapshot]])
        state.applyEvent(["type": "agent_settled"])
        state.beginHistory(id: "h", path: "/a")
        _ = state.receiveHistory(id: "h", path: "/a", items: [item("a", "user", "A"), item("q", "user", "ask"), item("r", "assistant", literal)])
        XCTAssertEqual(state.messages.map(\.text), ["A", "ask", literal])
        XCTAssertEqual(state.messages.last?.id, id)
    }

    func testSettlingWithoutMessageEndKeepsPartialAfterIdleHistory() throws {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "ask", connected: true)
        _ = state.resolvePrompt(id: "p", success: true)
        state.applyEvent(textDelta("partial"))
        let id = try XCTUnwrap(state.streamingID)
        state.disconnected()
        state.beginStateRequest(id: "state")
        _ = state.receiveState(id: "state", path: "/a", running: false)
        state.beginHistory(id: "h", path: "/a")
        _ = state.receiveHistory(id: "h", path: "/a", items: [item("a", "user", "A"), item("q", "user", "ask")])
        XCTAssertEqual(state.messages.last?.id, id)
        XCTAssertEqual(state.messages.last?.text, "partial")
        state.beginHistory(id: "final", path: "/a")
        _ = state.receiveHistory(id: "final", path: "/a", items: [item("a", "user", "A"), item("q", "user", "ask"), item("r", "assistant", "partial continued")])
        XCTAssertEqual(state.messages.last?.id, id)
        XCTAssertEqual(state.messages.map(\.text), ["A", "ask", "partial continued"])
    }

    func testEmptyFinalRetainsVisiblePartialAcrossSameBranchRefresh() throws {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "ask", connected: true)
        _ = state.resolvePrompt(id: "p", success: true)
        state.applyEvent(textDelta("interrupted"))
        let id = try XCTUnwrap(state.streamingID)
        state.applyEvent(["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "aborted"]])
        state.applyEvent(["type": "agent_settled"])
        XCTAssertEqual(state.messages.last?.text, "interrupted")
        state.beginHistory(id: "h", path: "/a")
        _ = state.receiveHistory(id: "h", path: "/a", items: [item("a", "user", "A"), item("q", "user", "ask")])
        XCTAssertEqual(state.messages.last?.text, "interrupted")
        XCTAssertEqual(state.messages.last?.id, id)
        state.beginHistory(id: "branch", path: "/a")
        _ = state.receiveHistory(id: "branch", path: "/a", items: [item("other", "user", "B")])
        XCTAssertEqual(state.messages.map(\.text), ["B"])
    }

    func testToolExecutionBeforeAnyTextPlacesProgressBeforeTheReply() {
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "检查文件", connected: true)
        state.applyEvent(["type": "tool_execution_start", "toolCallId": "1", "toolName": "read"])
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "1", "toolName": "read"])
        state.applyEvent(textDelta("找到文件了"))
        XCTAssertEqual(state.messages.suffix(3).map(\.role), [.user, .tool, .assistant])
    }

    func testLateToolUpdateDoesNotRollBackTerminalOutput() {
        var state = ConversationState()
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "1", "toolName": "read", "isError": true, "result": ["content": "文件不存在"]])
        state.applyEvent(["type": "tool_execution_update", "toolCallId": "1", "partialResult": ["content": "查找中"]])
        XCTAssertEqual(state.messages.map(\.text), ["文件不存在"])
    }

    func testPhasesAndConcurrentToolsShowOnlyConfirmedActivity() {
        var state = loadedState()
        state.applyEvent(["type": "run_phase", "phase": "thinking", "sessionPath": "/other"])
        XCTAssertEqual(state.runPhase, .waiting)
        state.applyEvent(["type": "run_phase", "phase": "thinking", "delta": "private"])
        XCTAssertEqual(state.runPhase, .thinking)
        XCTAssertFalse(state.messages.contains { $0.text.contains("private") })
        state.applyEvent(["type": "run_phase", "phase": "preparing_tool"])
        XCTAssertEqual(state.runPhase, .preparingTool)
        for id in ["a", "b"] { state.applyEvent(["type": "tool_execution_start", "toolCallId": id, "toolName": "read"]) }
        state.applyEvent(["type": "tool_execution_update", "toolCallId": "a", "partialResult": ["content": "读取中"]])
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "b", "isError": true, "durationMs": 123])
        XCTAssertEqual(state.messages.suffix(2).map(\.toolStatus), [.running, .failed])
        XCTAssertEqual(state.messages.suffix(2).first?.toolUpdates, 1)
        XCTAssertEqual(state.messages.last?.toolDurationMs, 123)
        state.disconnected()
        XCTAssertEqual(state.messages.suffix(2).map(\.toolStatus), [.unconfirmed, .failed])
        state.applyEvent(["type": "tool_execution_end", "toolCallId": "a"])
        XCTAssertEqual(state.messages.suffix(2).map(\.toolStatus), [.finished, .failed])
        state.applyEvent(textDelta("正文"))
        XCTAssertEqual(state.runPhase, .replying)
        state.applyEvent(["type": "agent_settled"])
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.runPhase, .waiting)
    }

    func testHistoryKeepsTheOptimisticPhotoAndRemovesOnlyTheImageHint() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGM4UCDxHwAFhAJIWblWNgAAAABJRU5ErkJggg=="))
        var state = loadedState()
        _ = state.preparePrompt(id: "p", text: "", image: bytes, connected: true)
        let local = try XCTUnwrap(state.messages.last { $0.role == .user })
        XCTAssertEqual(local.attachments.first?.data, bytes)
        state.beginHistory(id: "photos", path: "/a")
        let hint = "[Image: original 2853x2007, displayed at 2000x1407. Multiply coordinates by 1.43 to map to original image.]"
        _ = state.receiveHistory(id: "photos", path: "/a", items: [item("a", "user", "A"), item("photo", "user", hint)])
        XCTAssertEqual(state.messages.filter { $0.role == .user }.count, 2)
        let merged = try XCTUnwrap(state.messages.first { $0.sourceID == "photo" })
        XCTAssertEqual(merged.id, local.id)
        XCTAssertEqual(merged.text, "")
        XCTAssertEqual(merged.attachments.first?.data, bytes)
    }

    private func loadedState() -> ConversationState {
        var state = ConversationState()
        state.beginHistory(id: "initial", path: "/a")
        _ = state.receiveHistory(id: "initial", path: "/a", items: [item("a", "user", "A")])
        return state
    }

    private func item(_ id: String, _ role: String, _ text: String) -> [String: Any] {
        ["id": id, "role": role, "text": text]
    }

    private func textDelta(_ text: String) -> [String: Any] {
        ["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": text]]
    }
}

import Foundation
import CryptoKit

/// Session requests and the visible transcript share one context. A failed or late
/// request must never empty the transcript or redirect a prompt to an unseen session.
public struct ConversationState {
    public struct SessionChange {
        public let id: String
        public let path: String?
    }

    private struct HistoryRequest {
        let id: String
        let path: String
        let revision: Int
    }

    private struct Prompt {
        let text: String
        let userID: UUID
        let assistantID: UUID?
        let conversationID: UUID
    }

    public private(set) var messages: [ChatMessage] = []
    public private(set) var streamingID: UUID?
    public private(set) var isRunning = false
    public private(set) var sessionPath: String?
    public private(set) var activeSessionPath: String?
    public private(set) var conversationID = UUID()
    public private(set) var pendingChange: SessionChange?
    public private(set) var isWaitingForSessionResponse = false
    public private(set) var isSessionReady = true
    private var historyRequest: HistoryRequest?
    private var stateRequestID: String?
    private var stateRevision = 0
    private var prompts: [String: Prompt] = [:]
    private var toolMessageIDs: [String: UUID] = [:]
    private var revision = 0

    public init() {}

    public var isLoadingHistory: Bool { isWaitingForSessionResponse || historyRequest != nil }
    public var canSend: Bool { pendingChange == nil && isSessionReady }
    public var pendingHistoryID: String? { historyRequest?.id }
    public var pendingStateID: String? { stateRequestID }

    public mutating func preparePrompt(id: String, text: String, image: Data? = nil, connected: Bool) -> [String: Any]? {
        guard connected, canSend, !text.isEmpty || image != nil else { return nil }
        let user = ChatMessage(role: .user, text: text)
        messages.append(user)
        var assistantID: UUID?
        if !isRunning && streamingID == nil {
            let pending = ChatMessage(role: .assistant, text: "", streaming: true)
            messages.append(pending)
            streamingID = pending.id
            assistantID = pending.id
        }
        prompts[id] = Prompt(text: text, userID: user.id, assistantID: assistantID, conversationID: conversationID)
        isRunning = true
        revision += 1
        stateRequestID = nil
        var command: [String: Any] = ["type": "prompt", "id": id, "message": text, "streamingBehavior": "steer"]
        if let image {
            command["images"] = [["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"]]
        }
        return command
    }

    /// Only a definitive rejection restores the draft. Unknown delivery is never replayed.
    @discardableResult
    public mutating func resolvePrompt(id: String, success: Bool, disposition: String? = nil) -> String? {
        guard let prompt = prompts.removeValue(forKey: id), prompt.conversationID == conversationID else { return nil }
        if !success { messages.removeAll { $0.id == prompt.userID } }
        if !success || disposition == "handled" {
            if let assistantID = prompt.assistantID,
               let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].text.isEmpty {
                messages.remove(at: index)
                if streamingID == assistantID {
                    streamingID = nil
                    isRunning = !prompts.isEmpty
                }
            }
        }
        return success ? nil : prompt.text
    }

    public mutating func abandonPrompt(id: String) {
        // A socket error may occur after delivery. Keep the user's visible message;
        // get_state/history will reconcile it, and no automatic resend takes place.
        guard let prompt = prompts.removeValue(forKey: id), prompt.conversationID == conversationID else { return }
        if let assistantID = prompt.assistantID,
           let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].text.isEmpty {
            messages.remove(at: index)
            if streamingID == assistantID { streamingID = nil }
        }
    }

    @discardableResult
    public mutating func beginSessionChange(id: String, path: String?) -> Bool {
        guard pendingChange == nil else { return false }
        pendingChange = SessionChange(id: id, path: path)
        isWaitingForSessionResponse = true
        historyRequest = nil
        stateRequestID = nil
        return true
    }

    @discardableResult
    public mutating func resolveSessionChange(id: String, success: Bool, cancelled: Bool = false) -> Bool {
        guard let change = pendingChange, change.id == id else { return false }
        pendingChange = nil
        isWaitingForSessionResponse = false
        stateRequestID = nil
        guard success, !cancelled else {
            // Events were suppressed during the transition. Reconcile the actual
            // state before sending again, even when the native switch was cancelled.
            isSessionReady = false
            return false
        }
        activeSessionPath = change.path
        if change.path == nil {
            messages = []
            streamingID = nil
            isRunning = false
            sessionPath = nil
            conversationID = UUID()
            prompts = [:]
            toolMessageIDs = [:]
            isSessionReady = true
        } else {
            // Commit the visible session only when its history has arrived.
            isSessionReady = false
        }
        return true
    }

    public func historyAnchorID(for path: String) -> String? {
        guard path == sessionPath else { return nil }
        return messages.last(where: { $0.sourceID != nil })?.sourceID
    }

    public mutating func beginHistory(id: String, path: String) {
        guard pendingChange == nil else { return }
        historyRequest = HistoryRequest(id: id, path: path, revision: revision)
    }

    @discardableResult
    public mutating func receiveHistory(id: String, path: String?, items: [[String: Any]], hasEarlierMessages: Bool = false) -> Bool {
        guard let request = historyRequest, request.id == id,
              path == nil || path == request.path else { return false }
        historyRequest = nil
        let changed = sessionPath != request.path
        let previous = changed ? [] : messages
        let preserveTail = !changed && (isRunning || revision != request.revision || !prompts.isEmpty)
        messages = Self.mergeHistory(items, path: request.path, previous: previous, preserveTail: preserveTail, hasEarlierMessages: hasEarlierMessages)
        if changed {
            // Binding the first discovered path does not reset a new conversation.
            if sessionPath != nil || !isSessionReady { conversationID = UUID() }
            streamingID = nil
            isRunning = false
            prompts = [:]
            toolMessageIDs = [:]
        } else if !messages.contains(where: { $0.id == streamingID }) {
            streamingID = nil
        }
        toolMessageIDs = [:]
        for message in messages {
            if let callID = message.toolCallID { toolMessageIDs[callID] = message.id }
        }
        sessionPath = request.path
        activeSessionPath = request.path
        isSessionReady = true
        return true
    }

    public mutating func beginStateRequest(id: String) {
        stateRequestID = id
        stateRevision = revision
    }

    @discardableResult
    public mutating func receiveState(id: String, path: String?, running: Bool, messageCount: Int? = nil, sessionBarrier: Bool = false, sessionBarrierID: String? = nil) -> Bool {
        guard stateRequestID == id else { return false }
        if let pendingChange {
            // Only a gateway snapshot taken after native session handlers finish
            // can recover a lost ACK. A concurrent plain get_state cannot do this.
            guard !isWaitingForSessionResponse, sessionBarrier, sessionBarrierID == pendingChange.id else { return false }
            self.pendingChange = nil
            isSessionReady = false
        }
        stateRequestID = nil
        // Outside an unresolved native transition, a correlated state can recover
        // the active session after reconnect. Load its history before exposing it.
        activeSessionPath = path
        if let historyRequest, historyRequest.path != path { self.historyRequest = nil }
        if sessionPath == nil && isSessionReady {
            sessionPath = path
        } else {
            isSessionReady = sessionPath == path
        }
        if !isSessionReady, messageCount == 0, revision == stateRevision {
            messages = []
            streamingID = nil
            sessionPath = path
            conversationID = UUID()
            prompts = [:]
            toolMessageIDs = [:]
            historyRequest = nil
            isSessionReady = true
        }
        if revision == stateRevision {
            isRunning = running
            if !running { finishStreaming() }
        }
        return true
    }

    @discardableResult
    public mutating func failRequest(id: String, outcomeUnknown: Bool = false) -> Bool {
        if pendingChange?.id == id {
            // Native handlers run concurrently. A timeout or reconnect cannot prove
            // that a delayed switch has stopped; keep its ID for an ACK or barrier.
            isWaitingForSessionResponse = false
            if !outcomeUnknown { pendingChange = nil }
            return true
        }
        if historyRequest?.id == id {
            historyRequest = nil
            return true
        }
        if stateRequestID == id {
            stateRequestID = nil
            return true
        }
        return false
    }

    public mutating func disconnected() {
        isWaitingForSessionResponse = false
        historyRequest = nil
        stateRequestID = nil
        prompts.removeAll()
    }

    /// Events lack request IDs. Ignore events while a native session transition is
    /// unresolved; the acknowledged destination's history is the recovery boundary.
    @discardableResult
    public mutating func applyEvent(_ event: [String: Any]) -> ApprovalRequest? {
        // Session lifecycle hooks can await extension confirmation before the
        // switch ACK, so these requests must bypass the transcript event gate.
        if let approval = PiProjection.approval(from: event) { return approval }
        guard pendingChange == nil, isSessionReady else { return nil }
        if let path = event["sessionPath"] as? String, let sessionPath, path != sessionPath { return nil }
        switch event["type"] as? String {
        case "agent_start", "turn_start":
            isRunning = true
        case "message_update":
            let delta = PiProjection.delta(from: event)
            if let text = delta.text { appendStreaming(text) }
            // The execution lifecycle owns tool cards; toolcall_start is only
            // argument generation and would create a duplicate empty card.
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            let final = PiProjection.text(fromContent: message["content"])
            if let index = messages.firstIndex(where: { $0.id == streamingID }) {
                messages[index].text = final
                messages[index].streaming = false
            } else if !final.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: final))
            }
            streamingID = nil
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            guard let callID = event["toolCallId"] as? String else { return nil }
            let result = (event["result"] ?? event["partialResult"]) as? [String: Any]
            let text = PiProjection.text(fromContent: result?["content"])
            if let messageID = toolMessageIDs[callID], let index = messages.firstIndex(where: { $0.id == messageID }) {
                if result != nil { messages[index].text = text }
            } else {
                let message = ChatMessage(role: .tool, text: text, toolTitle: event["toolName"] as? String ?? "工具", toolCallID: callID)
                toolMessageIDs[callID] = message.id
                messages.append(message)
            }
        case "agent_end":
            finishStreaming()
        case "agent_settled":
            isRunning = false
            finishStreaming()
        default:
            return nil
        }
        revision += 1
        return nil
    }

    private mutating func appendStreaming(_ text: String) {
        if let index = messages.firstIndex(where: { $0.id == streamingID }) {
            messages[index].text += text
        } else {
            let message = ChatMessage(role: .assistant, text: text, streaming: true)
            messages.append(message)
            streamingID = message.id
        }
        isRunning = true
    }

    private mutating func finishStreaming() {
        if let index = messages.firstIndex(where: { $0.id == streamingID }) {
            if messages[index].text.isEmpty { messages.remove(at: index) }
            else { messages[index].streaming = false }
        }
        streamingID = nil
    }

    private static func mergeHistory(_ items: [[String: Any]], path: String, previous: [ChatMessage], preserveTail: Bool, hasEarlierMessages: Bool) -> [ChatMessage] {
        var consumed = Set<UUID>()
        var merged: [ChatMessage] = []
        for (offset, item) in items.enumerated() {
            guard let roleName = item["role"] as? String, let text = item["text"] as? String else { continue }
            let role: ChatRole = roleName == "user" ? .user : roleName == "tool" ? .tool : .assistant
            let sourceID = item["id"] as? String ?? "legacy-\(offset)"
            let tool = item["toolTitle"] as? String
            let callID = item["toolCallId"] as? String
            let available = previous.filter { !consumed.contains($0.id) }
            // A queued prompt or a parallel tool can be persisted in a different
            // order than its optimistic card. Never advance a positional cursor.
            let match = available.first { $0.sourceID == sourceID }
                ?? available.first { callID != nil && $0.toolCallID == callID }
                ?? available.first { old in
                    guard old.sourceID == nil, old.role == role, old.toolTitle == tool,
                          callID == nil || old.toolCallID == nil || old.toolCallID == callID else { return false }
                    return old.text == text || (old.streaming && !old.text.isEmpty && (text.hasPrefix(old.text) || old.text.hasPrefix(text)))
                }
            if var message = match {
                consumed.insert(message.id)
                if !message.streaming || !preserveTail || text.count >= message.text.count { message.text = text }
                message.sourceID = sourceID
                message.toolCallID = callID ?? message.toolCallID
                if !preserveTail { message.streaming = false }
                merged.append(message)
            } else {
                merged.append(ChatMessage(id: historyID(path: path, entry: sourceID), role: role, text: text, toolTitle: tool, sourceID: sourceID, toolCallID: callID))
            }
        }
        if hasEarlierMessages, let firstID = items.first?["id"] as? String,
           let boundary = previous.firstIndex(where: { $0.sourceID == firstID }) {
            // A bounded history window omits ancestors, not messages removed from
            // this branch. Keep the already-loaded prefix only with a shared anchor.
            let prefix = previous[..<boundary].filter { $0.sourceID != nil && !consumed.contains($0.id) }
            consumed.formUnion(prefix.map(\.id))
            merged.insert(contentsOf: prefix, at: 0)
        }
        if preserveTail {
            merged.append(contentsOf: previous.filter { !consumed.contains($0.id) && ($0.sourceID == nil || $0.streaming) })
        }
        return merged
    }

    private static func historyID(path: String, entry: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(path)\u{0}\(entry)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

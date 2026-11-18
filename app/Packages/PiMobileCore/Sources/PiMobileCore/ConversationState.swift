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
        var blocksDisplay: Bool
    }

    private struct Prompt {
        let user: ChatMessage
        let assistantID: UUID?
        let conversationID: UUID
        var unconfirmed = false
        var matchingHistory: ChatMessage?
    }

    public static let promptReceiptLimit = 32
    public private(set) var messages: [ChatMessage] = []
    public private(set) var streamingID: UUID?
    public private(set) var isRunning = false
    public private(set) var runPhase: RunPhase = .waiting
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
    private var interruptedIDs = Set<UUID>()
    private var awaitingRunState = false
    private var revision = 0

    public init() {}

    public var isLoadingHistory: Bool { isWaitingForSessionResponse || historyRequest?.blocksDisplay == true }
    public var canSend: Bool { pendingChange == nil && isSessionReady }
    public var pendingHistoryID: String? { historyRequest?.id }
    public var pendingStateID: String? { stateRequestID }
    public var hasPromptCapacity: Bool { prompts.count < Self.promptReceiptLimit }
    public var unconfirmedPromptIDs: [String] {
        prompts.compactMap { $0.value.unconfirmed ? $0.key : nil }.sorted()
    }

    public func hasPendingPrompt(id: String) -> Bool { prompts[id]?.conversationID == conversationID }

    public mutating func preparePrompt(id: String, text: String, image: Data? = nil, connected: Bool) -> [String: Any]? {
        guard connected, canSend, hasPromptCapacity, prompts[id] == nil, !text.isEmpty || image != nil else { return nil }
        let user = ChatMessage(role: .user, text: text, attachments: image.map { [ChatAttachments.localPhoto($0)] } ?? [])
        messages.append(user)
        var assistantID: UUID?
        if !isRunning {
            // A fresh prompt starts its own row after an interrupted connection.
            finishStreaming()
            runPhase = .waiting
            let pending = ChatMessage(role: .assistant, text: "", streaming: true)
            messages.append(pending)
            streamingID = pending.id
            assistantID = pending.id
        }
        prompts[id] = Prompt(user: user, assistantID: assistantID, conversationID: conversationID)
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
        if !success, let index = messages.firstIndex(where: { $0.id == prompt.user.id }) {
            // A display match by text could have been another device's message. Keep its exact saved content.
            if let saved = prompt.matchingHistory, messages[index].sourceID == saved.sourceID { messages[index] = saved }
            else { messages.remove(at: index) }
        }
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
        return success ? nil : prompt.user.text
    }

    public mutating func markPromptUnconfirmed(id: String) {
        // A deadline or socket error can follow delivery. Keep the original ID and user row for an exact receipt.
        guard let prompt = prompts[id], !prompt.unconfirmed else { return }
        prompts[id]?.unconfirmed = true
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
            awaitingRunState = false
            messages = []
            streamingID = nil
            isRunning = false
            runPhase = .waiting
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
        historyRequest = HistoryRequest(id: id, path: path, revision: revision,
            blocksDisplay: !isSessionReady || sessionPath != path || messages.isEmpty)
    }

    /// Keep the latest read eligible for a late reply. Only a required load needs a timeout banner.
    public mutating func historyTimedOut(id: String) -> Bool {
        guard historyRequest?.id == id, historyRequest?.blocksDisplay == true else { return false }
        historyRequest?.blocksDisplay = false
        return true
    }

    @discardableResult
    public mutating func receiveHistory(id: String, path: String?, items: [[String: Any]], hasEarlierMessages: Bool = false) -> Bool {
        guard let request = historyRequest, request.id == id,
              path == nil || path == request.path else { return false }
        historyRequest = nil
        // The first path can be assigned after sending a new conversation's first prompt.
        let changed = sessionPath != request.path && (sessionPath != nil || !isSessionReady)
        let previous = changed ? [] : messages
        let preserveTail = !changed && (isRunning || awaitingRunState || revision != request.revision || !prompts.isEmpty)
        messages = Self.mergeHistory(items, path: request.path, previous: previous, interruptedIDs: interruptedIDs, preserveTail: preserveTail, hasEarlierMessages: hasEarlierMessages, prompts: &prompts)
        interruptedIDs.formIntersection(messages.filter { $0.sourceID == nil }.map(\.id))
        if changed {
            conversationID = UUID()
            awaitingRunState = false
            streamingID = nil
            isRunning = false
            runPhase = .waiting
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
            awaitingRunState = false
            isRunning = running
            if !running { settleRun() }
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
        // Pi may finish offline. Keep the partial row for a resumed delta or history,
        // but only activity on the new connection can establish that Pi is running.
        if isRunning { awaitingRunState = true }
        isRunning = false
        if let index = messages.firstIndex(where: { $0.id == streamingID }) {
            messages[index].streaming = false
            interruptedIDs.insert(messages[index].id)
        }
        unconfirmActiveTools()
        runPhase = .waiting
        isWaitingForSessionResponse = false
        historyRequest = nil
        stateRequestID = nil
        for id in prompts.keys { markPromptUnconfirmed(id: id) }
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
            runPhase = .waiting
        case "run_phase":
            guard let raw = event["phase"] as? String, let phase = RunPhase(rawValue: raw),
                  phase == .thinking || phase == .preparingTool else { return nil }
            isRunning = true
            runPhase = phase
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any],
                  let type = update["type"] as? String else { return nil }
            if type == "thinking_start" || type == "toolcall_start" {
                // Earlier gateways may relay Pi's native event. Read only its type.
                isRunning = true
                runPhase = type == "thinking_start" ? .thinking : .preparingTool
                revision += 1
                return nil
            }
            guard ["text_start", "text_delta", "text_end"].contains(type) else { return nil }
            let snapshot = (event["message"] ?? update["partial"]) as? [String: Any]
            let visible = PiProjection.text(fromContent: snapshot?["content"])
            if !visible.isEmpty { updateStreaming(visible, replace: true) }
            else if let delta = PiProjection.delta(from: event).text, !delta.isEmpty { updateStreaming(delta) }
            // Tool execution events own their cards; argument generation has no transcript row.
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            let final = PiProjection.text(fromContent: message["content"])
            if !final.isEmpty { updateStreaming(final, replace: true) }
            finishStreaming(hasVisibleFinal: !final.isEmpty)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            guard applyToolEvent(event) else { return nil }
        case "agent_end":
            finishStreaming()
        case "agent_settled":
            settleRun()
        default:
            return nil
        }
        revision += 1
        return nil
    }

    private mutating func applyToolEvent(_ event: [String: Any]) -> Bool {
        guard let callID = event["toolCallId"] as? String, !callID.isEmpty else { return false }
        let type = event["type"] as? String
        let ended = type == "tool_execution_end"
        let result = (event["result"] ?? event["partialResult"]) as? [String: Any]
        let output = PiProjection.text(fromContent: result?["content"])
        let existing = toolMessageIDs[callID].flatMap { id in messages.firstIndex { $0.id == id } }
        var step = existing.map { messages[$0] } ?? ChatMessage(role: .tool, text: "", toolTitle: event["toolName"] as? String ?? "工具", toolCallID: callID, toolStatus: .running)
        if !ended, step.toolStatus == .finished || step.toolStatus == .failed { return false }
        if type == "tool_execution_update" { step.toolUpdates += 1 }
        if let name = event["toolName"] as? String, !name.isEmpty { step.toolTitle = name }
        if !output.isEmpty { step.text = output }
        if ended {
            step.toolStatus = event["isError"] as? Bool == true ? .failed : .finished
            if let duration = event["durationMs"] as? Int, duration >= 0 { step.toolDurationMs = duration }
        } else {
            step.toolStatus = .running
            isRunning = true
        }
        if let existing {
            messages[existing] = step
        } else {
            toolMessageIDs[callID] = step.id
            // A reserved answer row has no visible content yet. Keep earlier activity ahead of it.
            if let index = messages.firstIndex(where: { $0.id == streamingID && $0.text.isEmpty }) {
                messages.insert(step, at: index)
            } else {
                messages.append(step)
            }
        }
        if runPhase == .preparingTool || runPhase == .thinking { runPhase = .waiting }
        return true
    }

    private mutating func unconfirmActiveTools() {
        for index in messages.indices where messages[index].role == .tool && messages[index].toolStatus == .running {
            messages[index].toolStatus = .unconfirmed
        }
    }

    private mutating func settleRun() {
        awaitingRunState = false
        isRunning = false
        runPhase = .waiting
        unconfirmActiveTools()
        finishStreaming()
    }

    private mutating func updateStreaming(_ text: String, replace: Bool = false) {
        runPhase = .replying
        if let index = messages.firstIndex(where: { $0.id == streamingID }) {
            messages[index].streaming = true
            if replace { messages[index].text = text }
            else { messages[index].text += text }
        } else {
            let message = ChatMessage(role: .assistant, text: text, streaming: true)
            messages.append(message)
            streamingID = message.id
        }
        isRunning = true
    }

    private mutating func finishStreaming(hasVisibleFinal: Bool = false) {
        if let index = messages.firstIndex(where: { $0.id == streamingID }) {
            if messages[index].text.isEmpty { messages.remove(at: index) }
            else {
                messages[index].streaming = false
                if !hasVisibleFinal { interruptedIDs.insert(messages[index].id) }
            }
        }
        streamingID = nil
    }

    private static func mergeHistory(_ items: [[String: Any]], path: String, previous: [ChatMessage], interruptedIDs: Set<UUID>, preserveTail: Bool, hasEarlierMessages: Bool, prompts: inout [String: Prompt]) -> [ChatMessage] {
        let pendingUsers = Dictionary(uniqueKeysWithValues: prompts.map { ($0.value.user.id, $0.key) })
        var consumed = Set<UUID>()
        var merged: [ChatMessage] = []
        for (offset, item) in items.enumerated() {
            guard let roleName = item["role"] as? String, let role = ChatRole(rawValue: roleName),
                  let rawText = item["text"] as? String else { continue }
            let photoContent = role == .user ? ChatAttachments.project(content: rawText, attachments: item["attachments"]) : nil
            let text = photoContent?.text ?? rawText
            let photos = photoContent?.attachments ?? []
            let toolFailed = item["isError"] as? Bool == true
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
                          old.attachments.count == photos.count,
                          callID == nil || old.toolCallID == nil || old.toolCallID == callID else { return false }
                    let partial = old.streaming || interruptedIDs.contains(old.id)
                    return old.text == text || (partial && !old.text.isEmpty && (text.hasPrefix(old.text) || old.text.hasPrefix(text)))
                }
            func savedMessage() -> ChatMessage {
                ChatMessage(id: historyID(path: path, entry: sourceID), role: role, text: text, toolTitle: tool, sourceID: sourceID, toolCallID: callID, toolStatus: toolFailed ? .failed : .finished, attachments: photos)
            }
            if var message = match {
                if let id = pendingUsers[message.id] { prompts[id]?.matchingHistory = savedMessage() }
                consumed.insert(message.id)
                let partial = message.streaming || interruptedIDs.contains(message.id)
                if !partial || !preserveTail || text.count >= message.text.count { message.text = text }
                message.sourceID = sourceID
                message.toolCallID = callID ?? message.toolCallID
                if role == .tool, toolFailed || message.toolStatus != .failed { message.toolStatus = toolFailed ? .failed : .finished }
                if !photos.isEmpty {
                    message.attachments = photos.enumerated().map { index, photo in
                        if photo.data == nil, message.attachments.indices.contains(index) { return message.attachments[index] }
                        return photo
                    }
                }
                if !preserveTail { message.streaming = false }
                merged.append(message)
            } else {
                merged.append(savedMessage())
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
        // An idle snapshot can arrive before the gateway has persisted the interrupted
        // turn. Keep its local rows together if history still ends at their anchor.
        if !preserveTail {
            let anchor = previous.lastIndex { $0.sourceID != nil || consumed.contains($0.id) }
            let anchorID = anchor.map { previous[$0].id }
            if merged.last?.id == anchorID {
                let start = anchor.map { previous.index(after: $0) } ?? previous.startIndex
                let tail = previous[start...]
                if tail.contains(where: { interruptedIDs.contains($0.id) || $0.toolStatus == .unconfirmed }) {
                    merged.append(contentsOf: tail)
                    consumed.formUnion(tail.map(\.id))
                }
            }
        }
        // Pi omits empty finals from history. Keep a locally observed answer with its
        // original ID while the preceding row still belongs to this branch.
        for (offset, message) in previous.enumerated() where interruptedIDs.contains(message.id) && !consumed.contains(message.id) {
            guard offset > 0, let anchor = merged.firstIndex(where: { $0.id == previous[offset - 1].id }),
                  anchor + 1 == merged.count || merged[anchor + 1].role != .assistant else { continue }
            merged.insert(message, at: anchor + 1)
            consumed.insert(message.id)
        }
        if preserveTail {
            for row in previous where !consumed.contains(row.id) {
                if let id = pendingUsers[row.id], let prompt = prompts[id] {
                    // The saved branch no longer contains the display match. Its unconfirmed phone row still belongs here.
                    prompts[id]?.matchingHistory = nil
                    merged.append(prompt.user)
                } else if row.sourceID == nil || row.streaming {
                    merged.append(row)
                }
            }
        }
        return merged
    }

    private static func historyID(path: String, entry: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(path)\u{0}\(entry)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

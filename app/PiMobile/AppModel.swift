import Foundation
import Combine
import PiMobileCore

@MainActor
final class AppModel: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var messages: [ChatMessage] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var models: [ModelOption] = []
    @Published var selectedModel = ""
    @Published var thinking = "high"
    @Published var errorMessage: String?
    @Published var showConversation = false
    @Published var focusComposer = false
    @Published var draft = ""
    @Published var sessions: [[String: Any]] = []
    @Published var selectedSessionPath: String?
    @Published var selectedSessionTitle: String?
    @Published var isLoadingHistory = false
    @Published private(set) var conversationID = UUID()
    @Published private(set) var canSend = false
    @Published var needsRepair = false
    @Published private(set) var isPaired = false

    private let client = RelayClient()
    private var cancellables = Set<AnyCancellable>()
    private var conversation = ConversationState()
    private var serial = 0
    private var legacyCatalog = false
    private var transportConnected = false
    private var queuedSession: SessionDestination?
    private var requests: [String: RequestKind] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]

    private enum SessionDestination: Equatable {
        case new, existing(String)
        var path: String? { if case .existing(let path) = self { return path }; return nil }
    }

    private enum RequestKind {
        case state(refreshHistory: Bool), history, models, catalog, prompt, sessionChange(SessionDestination), command
    }

    init() {
        isPaired = client.hasPairing
        conversationID = conversation.conversationID
        client.onEvent = { [weak self] event in self?.apply(event) }
        client.onResponse = { [weak self] response in self?.applyResponse(response) }
        client.onPaired = { [weak self] _ in
            guard let self else { return }
            self.isPaired = true
            self.needsRepair = false
            self.apply(connectionState: .paired)
        }
        client.onDeviceStatus = { [weak self] online in
            guard let self else { return }
            if online, self.client.isConnected {
                self.refreshConversation()
            }
        }
        client.onSessionList = { [weak self] list in
            guard let self, self.legacyCatalog else { return }
            self.applySessionList(list)
        }

        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor in self?.apply(connectionState: state) }
            }
            .store(in: &cancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.errorMessage = message
                    if message.localizedCaseInsensitiveContains("配对")
                        || message.localizedCaseInsensitiveContains("密钥")
                        || message.localizedCaseInsensitiveContains("加密") {
                        self.needsRepair = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 连接生命周期

    var isConnected: Bool { client.isConnected }

    func bootstrap() {
        if ProcessInfo.processInfo.environment["PI_MOBILE_RESET_PAIRING"] == "1" {
            resetPairing()
            return
        }
        guard isPaired else { return }
        client.connectIfNeeded()
    }

    func resume() {
        guard isPaired else { return }
        if client.isConnected { refreshConversation() }
        else { client.connectIfNeeded() }
    }

    func reconnect() {
        client.connect()
    }

    func pair(token: String) {
        errorMessage = nil
        needsRepair = false
        client.pair(token: token)
    }

    func resetPairing() {
        client.resetPairing()
        isPaired = false
        needsRepair = false
        connection = .idle
        errorMessage = nil
        cancelRequests()
        queuedSession = nil
        conversation = ConversationState()
        publishConversation()
        approvals.removeAll()
        sessions.removeAll()
        models.removeAll()
        selectedModel = ""
        selectedSessionPath = nil
        selectedSessionTitle = nil
        showConversation = false
        draft = ""
    }

    func clearError() { errorMessage = nil }

    // MARK: - 会话

    func loadSessions() {
        guard client.isConnected else { return }
        if legacyCatalog {
            send(["type": "session_list"], failure: "加载会话列表失败")
            return
        }
        // Only accept the most recently requested list, which may include a newer turn.
        for (id, kind) in requests {
            if case .catalog = kind { finishRequest(id) }
        }
        let id = nextID("catalog")
        sendRPC(["type": "session_catalog", "id": id], kind: .catalog, failure: "加载会话列表失败")
    }

    func applySessionList(_ list: [[String: Any]]) {
        sessions = list
        if let path = selectedSessionPath, let entry = list.first(where: { ($0["path"] as? String) == path }).flatMap(PiSessionEntry.init) {
            selectedSessionTitle = entry.title
        }
    }

    func newSession() { selectSession(.new) }

    func switchSession(_ path: String) {
        guard !path.isEmpty else { return }
        selectSession(.existing(path))
    }

    private func selectSession(_ destination: SessionDestination) {
        focusComposer = false
        showConversation = true
        guard client.isConnected else {
            errorMessage = "连接已断开，请连接后再打开会话"
            client.connectIfNeeded()
            return
        }
        // Native commands are asynchronous. Serialize them so a late switch cannot
        // undo the user's newer selection on the gateway.
        if let pending = conversation.pendingChange {
            guard conversation.isWaitingForSessionResponse else {
                errorMessage = "上一次切换结果尚未确认，请等待确认后再切换"
                return
            }
            queuedSession = pending.path == destination.path ? nil : destination
            return
        }
        if case .existing(let path) = destination,
           conversation.sessionPath == path, conversation.isSessionReady {
            refreshConversation()
            return
        }
        startSessionChange(destination)
    }

    private func startSessionChange(_ destination: SessionDestination) {
        let id = nextID("session")
        guard conversation.beginSessionChange(id: id, path: destination.path) else { return }
        discardReadRequests()
        publishConversation()
        var command: [String: Any] = ["type": destination.path == nil ? "new_session" : "switch_session", "id": id]
        if let path = destination.path { command["sessionPath"] = path }
        sendRPC(command, kind: .sessionChange(destination), failure: "切换会话失败")
    }

    private func continueQueuedSession() -> Bool {
        guard let destination = queuedSession else { return false }
        queuedSession = nil
        startSessionChange(destination)
        return true
    }

    func sessionTitle(for path: String) -> String {
        sessions.first(where: { ($0["path"] as? String) == path }).flatMap(PiSessionEntry.init)?.title ?? "当前会话"
    }

    // MARK: - 消息与指令

    @discardableResult
    func send(image: Data? = nil) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || image != nil else { return false }
        let id = nextID("prompt")
        guard let command = conversation.preparePrompt(id: id, text: text, image: image, connected: client.isConnected) else {
            errorMessage = client.isConnected ? "请等待会话加载完成后发送" : "连接已断开，草稿已保留，请连接后发送"
            client.connectIfNeeded()
            return false
        }
        draft = ""
        publishConversation()
        sendRPC(command, kind: .prompt, failure: "发送结果未确认，不会自动重发")
        return true
    }

    func stop() {
        serial += 1
        sendRPC(["type": "abort", "id": "m\(serial)"], failure: "停止失败")
    }

    func chooseModel(_ option: ModelOption) {
        selectedModel = option.id
        serial += 1
        sendRPC([
            "type": "set_model",
            "id": "m\(serial)",
            "provider": option.provider,
            "modelId": option.modelId,
        ], failure: "切换模型失败")
    }

    func setThinking(_ level: String) {
        thinking = level
        serial += 1
        sendRPC(["type": "set_thinking_level", "id": "m\(serial)", "level": level], failure: "切换思考强度失败")
    }

    func answer(_ request: ApprovalRequest, confirmed: Bool, value: String? = nil) {
        var payload: [String: Any] = ["type": "extension_ui_response", "id": request.id]
        if request.method == "confirm" {
            payload["confirmed"] = confirmed
        } else {
            payload["value"] = confirmed ? (value ?? "") : ""
            payload["cancelled"] = !confirmed
        }
        approvals.removeAll { $0.id == request.id }
        syncLive()
        send(payload, failure: "审批失败")
    }

    // MARK: - 底层发送

    private func nextID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private func send(_ object: [String: Any], failure: String) {
        Task {
            do { try await client.send(object) }
            catch { errorMessage = "\(failure)：\(error.localizedDescription)" }
        }
    }

    private func sendRPC(_ command: [String: Any], kind: RequestKind = .command, failure: String) {
        guard let id = command["id"] as? String else { return }
        requests[id] = kind
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            self?.requestFailed(id: id, message: "\(failure)：等待响应超时", outcomeUnknown: true)
        }
        Task {
            do { try await client.send(["type": "rpc", "id": id, "command": command]) }
            catch { requestFailed(id: id, message: "\(failure)：\(error.localizedDescription)", outcomeUnknown: true) }
        }
    }

    @discardableResult
    private func finishRequest(_ id: String) -> RequestKind? {
        deadlines.removeValue(forKey: id)?.cancel()
        return requests.removeValue(forKey: id)
    }

    private func cancelRequests(keepingSessionChange: Bool = false) {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        requests = requests.filter { id, _ in keepingSessionChange && id == conversation.pendingChange?.id }
    }

    private func discardReadRequests() {
        let ids = requests.compactMap { id, kind -> String? in
            switch kind {
            case .state, .history: return id
            default: return nil
            }
        }
        for id in ids { finishRequest(id) }
    }

    private func requestFailed(id: String, message: String, outcomeUnknown: Bool) {
        guard let kind = requests[id] else { return }
        if case .sessionChange = kind, outcomeUnknown {
            // Keep the original ID so its late ACK can finish the transition. A
            // concurrent get_state response is not a completion barrier for pi.
            deadlines.removeValue(forKey: id)?.cancel()
            _ = conversation.failRequest(id: id, outcomeUnknown: true)
            queuedSession = nil
            errorMessage = "\(message)；切换结果尚未确认，已暂停发送"
            publishConversation()
            requestState(refreshHistory: true)
            return
        }
        finishRequest(id)
        var reconcile = false
        switch kind {
        case .prompt:
            conversation.abandonPrompt(id: id)
            reconcile = true
        case .sessionChange:
            _ = conversation.failRequest(id: id, outcomeUnknown: outcomeUnknown)
            // Do not dispatch a queued transition when the preceding result is unknown.
            queuedSession = nil
            reconcile = true
        case .state, .history:
            guard conversation.failRequest(id: id) else { return }
        case .models, .catalog, .command:
            break
        }
        errorMessage = message
        publishConversation()
        if reconcile, client.isConnected { requestState(refreshHistory: true) }
    }

    private func requestState(refreshHistory: Bool = false) {
        guard client.isConnected, !conversation.isWaitingForSessionResponse else { return }
        if let previous = conversation.pendingStateID { finishRequest(previous) }
        let id = nextID("state")
        conversation.beginStateRequest(id: id)
        var command: [String: Any] = ["type": "get_state", "id": id]
        if let pending = conversation.pendingChange { command["afterSessionChangeId"] = pending.id }
        sendRPC(command, kind: .state(refreshHistory: refreshHistory), failure: "获取状态失败")
    }

    private func requestModels() {
        guard client.isConnected else { return }
        let id = nextID("models")
        sendRPC(["type": "get_available_models", "id": id], kind: .models, failure: "获取模型列表失败")
    }

    private func requestHistory(path: String) {
        guard client.isConnected, conversation.pendingChange == nil else { return }
        if let previous = conversation.pendingHistoryID { finishRequest(previous) }
        let id = nextID("history")
        conversation.beginHistory(id: id, path: path)
        publishConversation()
        var command: [String: Any] = ["type": "session_history", "id": id, "sessionPath": path]
        if let anchorID = conversation.historyAnchorID(for: path) { command["anchorId"] = anchorID }
        sendRPC(command, kind: .history, failure: "加载历史失败")
    }

    private func refreshConversation() {
        guard !conversation.isWaitingForSessionResponse else { return }
        requestState(refreshHistory: true)
        // Refresh the known transcript even when streaming events supersede a state
        // snapshot. The history merge retains newer deltas and visible message IDs.
        if conversation.isSessionReady, !conversation.messages.isEmpty, let path = conversation.sessionPath { requestHistory(path: path) }
    }

    // MARK: - 响应投影

    private func applyResponse(_ response: [String: Any]) {
        guard let id = response["id"] as? String, let kind = requests[id] else { return }
        let success = response["success"] as? Bool == true
        let data = response["data"] as? [String: Any]
        if !success {
            finishRequest(id)
            switch kind {
            case .catalog:
                // Earlier gateways forward this extension to Pi, which rejects it as unknown.
                if let error = response["error"] as? String, error.localizedCaseInsensitiveContains("unknown command"),
                   error.contains("session_catalog") {
                    legacyCatalog = true
                    loadSessions()
                    return
                }
            case .prompt:
                if let restored = conversation.resolvePrompt(id: id, success: false) {
                    draft = draft.isEmpty ? restored : restored + "\n" + draft
                }
            case .sessionChange:
                _ = conversation.resolveSessionChange(id: id, success: false)
                if continueQueuedSession() { return }
                refreshConversation()
            case .history, .state:
                guard conversation.failRequest(id: id) else { return }
            default: break
            }
            errorMessage = response["error"] as? String ?? "请求失败"
            publishConversation()
            return
        }

        switch kind {
        case .catalog:
            guard let list = data?["sessions"] as? [[String: Any]] else {
                requestFailed(id: id, message: "会话列表响应无效", outcomeUnknown: false)
                return
            }
            finishRequest(id)
            applySessionList(list)
            return
        case .models:
            finishRequest(id)
            models = PiProjection.modelOptions(from: response["data"])
        case .prompt:
            finishRequest(id)
            _ = conversation.resolvePrompt(id: id, success: true, disposition: data?["disposition"] as? String)
        case .sessionChange(let destination):
            finishRequest(id)
            let cancelled = data?["cancelled"] as? Bool == true
            let changed = conversation.resolveSessionChange(id: id, success: true, cancelled: cancelled)
            if continueQueuedSession() { return }
            if changed {
                errorMessage = nil
                approvals.removeAll()
                if let path = destination.path {
                    requestHistory(path: path)
                } else {
                    selectedSessionTitle = "新建会话"
                    focusComposer = true
                    // A native new_session path may not exist until its first message.
                    requestState()
                }
                loadSessions()
            } else if cancelled {
                errorMessage = "切换会话已取消"
                refreshConversation()
            }
        case .state(let refreshHistory):
            guard let data, let streaming = data["isStreaming"] as? Bool else {
                requestFailed(id: id, message: "状态响应无效", outcomeUnknown: false)
                return
            }
            finishRequest(id)
            let path = data["sessionFile"] as? String
            let running = streaming || data["isCompacting"] as? Bool == true || (data["pendingMessageCount"] as? Int ?? 0) > 0
            let recoveringChangeID = conversation.pendingChange?.id
            guard conversation.receiveState(id: id, path: path, running: running, messageCount: data["messageCount"] as? Int,
                                            sessionBarrier: data["sessionBarrier"] as? Bool == true,
                                            sessionBarrierID: data["sessionBarrierId"] as? String) else { return }
            if let recoveringChangeID, conversation.pendingChange == nil {
                finishRequest(recoveringChangeID)
                errorMessage = nil
            }
            applyModelState(data)
            // Empty native sessions have a future path before the file is created.
            let hasHistory = data["messageCount"] as? Int != 0
            if (refreshHistory || !conversation.isSessionReady), hasHistory, let path, conversation.pendingHistoryID == nil {
                requestHistory(path: path)
            }
        case .history:
            guard let items = data?["messages"] as? [[String: Any]] else {
                requestFailed(id: id, message: "历史响应无效", outcomeUnknown: false)
                return
            }
            let wasReady = conversation.isSessionReady
            guard conversation.receiveHistory(id: id, path: data?["sessionPath"] as? String, items: items, hasEarlierMessages: data?["hasEarlierMessages"] as? Bool == true) else { return }
            finishRequest(id)
            if !wasReady { requestState() }
        case .command:
            finishRequest(id)
        }
        publishConversation()
    }

    private func applyModelState(_ data: [String: Any]) {
        if let model = data["model"] as? [String: Any],
           let provider = model["provider"] as? String,
           let modelId = (model["id"] as? String) ?? (model["modelId"] as? String) {
            selectedModel = "\(provider)/\(modelId)"
        }
        if let level = data["thinkingLevel"] as? String { thinking = level }
    }

    private func apply(_ event: [String: Any]) {
        if let approval = conversation.applyEvent(event), !approvals.contains(where: { $0.id == approval.id }) {
            approvals.append(approval)
        }
        publishConversation()
        if event["type"] as? String == "agent_end" {
            // agent_end ends a low-level run. A correlated snapshot also supports
            // older pi versions which do not emit agent_settled.
            requestState()
            loadSessions()
        }
    }

    private func publishConversation() {
        if conversationID != conversation.conversationID { conversationID = conversation.conversationID }
        if messages != conversation.messages { messages = conversation.messages }
        if selectedSessionPath != conversation.sessionPath {
            selectedSessionPath = conversation.sessionPath
            if let path = conversation.sessionPath { selectedSessionTitle = sessionTitle(for: path) }
        }
        isLoadingHistory = conversation.isLoadingHistory
        canSend = client.isConnected && conversation.canSend
        if client.isConnected { connection = conversation.isRunning ? .running : .paired }
        syncLive()
    }

    private func apply(connectionState state: ConnectionState) {
        let connected = state == .paired || state == .running
        let newlyConnected = connected && !transportConnected
        transportConnected = connected
        if !connected {
            conversation.disconnected()
            queuedSession = nil
            cancelRequests(keepingSessionChange: true)
            if conversation.pendingChange != nil { errorMessage = "连接中断时会话切换尚未确认，已保留原会话并暂停发送" }
            connection = state
            if state == .error, errorMessage == nil { errorMessage = "连接出错" }
        }
        publishConversation()
        if newlyConnected {
            legacyCatalog = false
            refreshConversation()
            requestModels()
            loadSessions()
        }
    }

    private func syncLive() {
        let phase: SessionActivityPhase = !approvals.isEmpty ? .awaitingApproval
            : connection == .running ? .running : .idle
        LiveActivityManager.shared.sync(
            sessionID: "current", title: "Pi", phase: phase,
            approvalCount: approvals.count, model: selectedModel,
            modeLabel: thinking, workspaceShort: "pi", lastToolName: nil)
    }
}

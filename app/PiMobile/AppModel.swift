import Foundation
import Combine
import PiMobileCore

@MainActor
final class AppModel: ObservableObject {
    @Published var connection: ConnectionState = .idle
    @Published var messages: [ChatMessage] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var runPhase: RunPhase = .waiting
    @Published var models: [ModelOption] = []
    @Published var selectedModel = ""
    @Published var thinking = "high"
    @Published private var connectionError: String?
    @Published private var actionError: String?
    @Published private var stateReadError: StateReadError?
    @Published private var historyReadError: String?
    @Published private(set) var settingError: String?
    @Published private var promptError: String?
    @Published private var unconfirmedPromptNotice: String?
    private var failureMessage: String? {
        connectionError ?? settingError ?? actionError ?? promptError ?? historyReadError ?? stateReadError?.message
    }
    var pendingDeliveryNotice: String? { isConnected && failureMessage == nil ? unconfirmedPromptNotice : nil }
    var errorMessage: String? { failureMessage ?? pendingDeliveryNotice }
    @Published var showConversation = false
    @Published var focusComposer = false
    @Published var draft = ""
    /// Advances on local sends, including photos and follow-ups during a run.
    @Published private(set) var submittedPromptID: String?
    @Published var sessions: [[String: Any]] = []
    @Published var selectedSessionPath: String?
    @Published var selectedSessionTitle: String?
    @Published var isLoadingHistory = false
    @Published private(set) var conversationID = UUID()
    @Published private(set) var canSend = false
    var needsRepair: Bool {
        guard connection == .error, let message = connectionError else { return false }
        return ["配对", "密钥", "加密", "not paired"].contains { message.localizedCaseInsensitiveContains($0) }
    }
    @Published private(set) var isPaired = false

    var canChangeSettings: Bool { isConnected && conversation.canSend && !recoveringSetting && queuedSession == nil }

    private let client: RelayClient
    private let rpcTimeout: Duration
    private var confirmedModel = ""
    private var confirmedThinking = "high"
    private var settingInFlight: (id: String, change: SettingChange)?
    private var settingQueue: [SettingChange] = []
    private var recoveringSetting = false
    private var transportGeneration = 0
    private var conversation = ConversationState()
    private var serial = 0
    private var legacyCatalog = false
    private var transportConnected = false
    private var queuedSession: SessionDestination?
    private var requests: [String: RequestKind] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var dismissedPromptIDs = Set<String>()
    private var deferredPromptReceipts: [String: PromptReceipt] = [:]

    private struct PromptReceipt {
        let id: String
        let success: Bool
        let disposition: String?
        let error: String?

        init?(_ object: [String: Any]) {
            guard let id = object["id"] as? String, let success = object["success"] as? NSNumber,
                  CFGetTypeID(success) == CFBooleanGetTypeID() else { return nil }
            self.id = id
            self.success = success.boolValue
            disposition = (object["data"] as? [String: Any])?["disposition"] as? String
            error = object["error"] as? String
        }
    }

    private enum SessionDestination: Equatable {
        case new, existing(String)
        var path: String? { if case .existing(let path) = self { return path }; return nil }
    }

    private enum SettingChange {
        case model(ModelOption), thinking(String)

        var isModel: Bool { if case .model = self { return true }; return false }
        func apply(model: inout String, thinking: inout String) {
            switch self {
            case .model(let option): model = option.id
            case .thinking(let level): thinking = level
            }
        }
    }

    private enum StateReadError {
        case timedOut, failed(String)

        var message: String {
            switch self {
            case .timedOut: return "获取状态失败：等待响应超时"
            case .failed(let message): return message
            }
        }
    }

    private enum RequestKind {
        case state(refreshHistory: Bool, promptReceiptIDs: Set<String>), history, models, catalog, prompt, sessionChange(SessionDestination), setting, command
    }

    convenience init() { self.init(client: RelayClient()) }

    init(client: RelayClient, rpcTimeout: Duration = .seconds(15)) {
        self.client = client
        self.rpcTimeout = rpcTimeout
        isPaired = client.hasPairing
        conversationID = conversation.conversationID
        client.onEvent = { [weak self] event in self?.apply(event) }
        client.onResponse = { [weak self] response in self?.applyResponse(response) }
        client.onPaired = { [weak self] _ in self?.isPaired = true }
        client.onConnectionChange = { [weak self] state, error in
            self?.apply(connectionState: state, error: error)
        }
        client.onActionError = { [weak self] message in self?.actionError = message }
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

        apply(connectionState: client.state, error: client.lastError)
    }

    // MARK: - 连接生命周期

    var isConnected: Bool { connection == .paired || connection == .running }

    func bootstrap() {
        if ProcessInfo.processInfo.environment["PI_MOBILE_RESET_PAIRING"] == "1" {
            resetPairing()
            return
        }
        guard isPaired else { return }
        client.connectIfNeeded()
    }

    func resume() {
        client.setForeground(true)
        guard isPaired else { return }
        if client.isConnected { refreshConversation() }
        else { client.connectIfNeeded() }
    }

    func suspendConnectionChecks() { client.setForeground(false) }

    func reconnect() {
        client.connect()
    }

    func pair(token: String) {
        clearError()
        client.pair(token: token)
    }

    func resetPairing() {
        client.resetPairing()
        isPaired = false
        connection = .idle
        clearError()
        settingInFlight = nil
        settingQueue = []
        recoveringSetting = false
        confirmedModel = ""
        confirmedThinking = "high"
        publishSettings()
        cancelRequests()
        queuedSession = nil
        conversation = ConversationState()
        publishConversation()
        approvals.removeAll()
        sessions.removeAll()
        models.removeAll()
        selectedSessionPath = nil
        selectedSessionTitle = nil
        showConversation = false
        draft = ""
    }

    func dismissSettingError() { settingError = nil }

    func clearError() {
        if pendingDeliveryNotice != nil {
            dismissedPromptIDs.formUnion(conversation.unconfirmedPromptIDs)
            unconfirmedPromptNotice = nil
        }
        connectionError = nil
        settingError = nil
        actionError = nil
        promptError = nil
        stateReadError = nil
        historyReadError = nil
    }

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
            connectionError = "连接已断开，请连接后再打开会话"
            client.connectIfNeeded()
            return
        }
        if settingInFlight != nil {
            queuedSession = destination
            return
        }
        // Native commands are asynchronous. Serialize them so a late switch cannot
        // undo the user's newer selection on the gateway.
        if let pending = conversation.pendingChange {
            guard conversation.isWaitingForSessionResponse else {
                actionError = "上一次切换结果尚未确认，请等待确认后再切换"
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
        guard settingInFlight == nil, queuedSession == nil else { return false }
        let id = nextID("prompt")
        guard let command = conversation.preparePrompt(id: id, text: text, image: image, connected: client.isConnected) else {
            if client.isConnected {
                if !conversation.hasPromptCapacity { promptError = "已有 \(ConversationState.promptReceiptLimit) 条消息等待确认，草稿已保留。" }
                else { actionError = "请等待会话加载完成后发送" }
            } else {
                connectionError = "连接已断开，草稿已保留，请连接后发送"
                client.connectIfNeeded()
            }
            return false
        }
        draft = ""
        submittedPromptID = id
        publishConversation()
        sendRPC(command, kind: .prompt, failure: "发送结果未确认，不会自动重发")
        return true
    }

    func stop() {
        serial += 1
        sendRPC(["type": "abort", "id": "m\(serial)"], failure: "停止失败")
    }

    func chooseModel(_ option: ModelOption) {
        guard option.id != selectedModel else { return }
        enqueueSetting(.model(option))
    }

    func setThinking(_ level: String) {
        guard level != thinking else { return }
        enqueueSetting(.thinking(level))
    }

    private func enqueueSetting(_ change: SettingChange) {
        guard canChangeSettings else { return }
        settingError = nil
        // Retain only the latest unsent choice for each control, in tap order.
        settingQueue.removeAll { $0.isModel == change.isModel }
        settingQueue.append(change)
        sendNextSetting()
        publishSettings()
        publishConversation()
    }

    private func sendNextSetting() {
        guard settingInFlight == nil, !settingQueue.isEmpty else { return }
        let change = settingQueue.removeFirst()
        let id = nextID("setting")
        settingInFlight = (id, change)
        switch change {
        case .model(let option):
            sendRPC(["type": "set_model", "id": id, "provider": option.provider, "modelId": option.modelId],
                    kind: .setting, failure: "切换模型失败")
        case .thinking(let level):
            sendRPC(["type": "set_thinking_level", "id": id, "level": level], kind: .setting, failure: "切换思考强度失败")
        }
    }

    private func publishSettings() {
        var model = confirmedModel, level = confirmedThinking
        settingInFlight?.change.apply(model: &model, thinking: &level)
        for change in settingQueue { change.apply(model: &model, thinking: &level) }
        if selectedModel != model { selectedModel = model }
        if thinking != level { thinking = level }
    }

    private func finishSetting(id: String, error: String?) {
        guard let pending = settingInFlight, pending.id == id else { return }
        finishRequest(id)
        if let error {
            if !settingQueue.contains(where: { $0.isModel == pending.change.isModel }) { settingError = error }
        } else {
            pending.change.apply(model: &confirmedModel, thinking: &confirmedThinking)
            if recoveringSetting { settingError = nil }
        }
        settingInFlight = nil
        recoveringSetting = false
        sendNextSetting()
        publishSettings()
        if settingInFlight == nil, !continueQueuedSession() { requestState() }
        publishConversation()
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
            catch { actionError = "\(failure)：\(error.localizedDescription)" }
        }
    }

    private func sendRPC(_ command: [String: Any], kind: RequestKind = .command, failure: String) {
        guard let id = command["id"] as? String else { return }
        requests[id] = kind
        let generation = transportGeneration
        deadlines[id] = Task { [weak self, rpcTimeout] in
            do { try await Task.sleep(for: rpcTimeout) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            deadlines.removeValue(forKey: id)
            let message = "\(failure)：等待响应超时"
            switch requests[id] {
            case .state:
                // A snapshot can wait behind a native mutation. Keep the ID for readback.
                if conversation.pendingStateID == id, connection != .running { stateReadError = .timedOut }
            case .history:
                // Both reads can still succeed. A visible transcript can refresh silently.
                if conversation.historyTimedOut(id: id) { historyReadError = message }
                publishConversation()
            default:
                requestFailed(id: id, message: message, outcomeUnknown: true)
            }
        }
        Task {
            guard generation == transportGeneration, requests[id] != nil else { return }
            do { try await client.send(["type": "rpc", "id": id, "command": command]) }
            catch { requestFailed(id: id, message: "\(failure)：\(error.localizedDescription)", outcomeUnknown: true) }
        }
    }

    @discardableResult
    private func finishRequest(_ id: String) -> RequestKind? {
        deadlines.removeValue(forKey: id)?.cancel()
        return requests.removeValue(forKey: id)
    }

    private func cancelRequests(keepingMutations: Bool = false) {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        requests = requests.filter { id, _ in
            keepingMutations && (id == conversation.pendingChange?.id || id == settingInFlight?.id)
        }
    }

    private func discardReadRequests() {
        stateReadError = nil
        historyReadError = nil
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
        if case .setting = kind {
            if outcomeUnknown {
                deadlines.removeValue(forKey: id)?.cancel()
                markSettingUncertain()
                requestState()
                publishConversation()
            } else { finishSetting(id: id, error: message) }
            return
        }
        if case .sessionChange = kind, outcomeUnknown {
            // Keep the original ID so its late ACK can finish the transition. A
            // concurrent get_state response is not a completion barrier for pi.
            deadlines.removeValue(forKey: id)?.cancel()
            _ = conversation.failRequest(id: id, outcomeUnknown: true)
            queuedSession = nil
            actionError = "\(message)；切换结果尚未确认，已暂停发送"
            publishConversation()
            requestState(refreshHistory: true)
            return
        }
        finishRequest(id)
        var reconcile = false
        switch kind {
        case .prompt:
            guard conversation.hasPendingPrompt(id: id) else { return }
            conversation.markPromptUnconfirmed(id: id)
            publishConversation()
            requestState(refreshHistory: true)
            return
        case .sessionChange:
            _ = conversation.failRequest(id: id, outcomeUnknown: outcomeUnknown)
            // Do not dispatch a queued transition when the preceding result is unknown.
            queuedSession = nil
            reconcile = true
        case .state, .history:
            guard conversation.failRequest(id: id) else { return }
        case .models, .catalog, .command, .setting:
            break
        }
        recordRequestError(message, for: kind)
        publishConversation()
        if reconcile, client.isConnected { requestState(refreshHistory: true) }
    }

    private func recordRequestError(_ message: String, for kind: RequestKind) {
        switch kind {
        case .state: stateReadError = .failed(message)
        case .history: historyReadError = message
        default: actionError = message
        }
    }

    private func requestState(refreshHistory: Bool = false) {
        guard client.isConnected, !conversation.isWaitingForSessionResponse else { return }
        var needsHistory = refreshHistory
        // A prompt invalidates the transcript snapshot but still needs its settings.
        // Supersede every older state read, including those no longer owned by the transcript.
        for (id, kind) in requests {
            if case .state(let previousRefresh, _) = kind {
                needsHistory = needsHistory || previousRefresh
                finishRequest(id)
            }
        }
        let id = nextID("state")
        conversation.beginStateRequest(id: id)
        var command: [String: Any] = ["type": "get_state", "id": id]
        if let pending = conversation.pendingChange { command["afterSessionChangeId"] = pending.id }
        if recoveringSetting { command["afterSettingChangeId"] = settingInFlight?.id }
        let ids = conversation.canSend ? conversation.unconfirmedPromptIDs : []
        if !ids.isEmpty { command["promptReceiptIds"] = ids }
        sendRPC(command, kind: .state(refreshHistory: needsHistory, promptReceiptIDs: Set(ids)), failure: "获取状态失败")
    }

    private func requestModels() {
        guard client.isConnected else { return }
        let id = nextID("models")
        sendRPC(["type": "get_available_models", "id": id], kind: .models, failure: "获取模型列表失败")
    }

    private func requestHistory(path: String) {
        guard client.isConnected, conversation.pendingChange == nil else { return }
        for (id, kind) in requests {
            if case .history = kind { finishRequest(id) }
        }
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

    private func applyPromptReceipt(_ receipt: PromptReceipt) {
        guard conversation.hasPendingPrompt(id: receipt.id) else { return }
        // A switch may be cancelled. Hold its old conversation's result until the visible destination is known.
        guard conversation.canSend else {
            deferredPromptReceipts[receipt.id] = deferredPromptReceipts[receipt.id] ?? receipt
            return
        }
        let restored = conversation.resolvePrompt(id: receipt.id, success: receipt.success, disposition: receipt.disposition)
        if let restored {
            if !restored.isEmpty { draft = draft.isEmpty ? restored : restored + "\n" + draft }
            promptError = receipt.error ?? "Mac 未能接收这条消息"
        }
    }

    private func applyResponse(_ response: [String: Any]) {
        guard let id = response["id"] as? String else { return }
        // Deadlines only end the wait. An encrypted reply to this exact prompt is still authoritative.
        if conversation.hasPendingPrompt(id: id) {
            guard response["command"] == nil || response["command"] as? String == "prompt",
                  let receipt = PromptReceipt(response) else { return }
            finishRequest(id)
            if receipt.success { clearStateTimeout() }
            applyPromptReceipt(receipt)
            publishConversation()
            return
        }
        guard let kind = requests[id] else { return }
        if case .prompt = kind { finishRequest(id); return } // The conversation was replaced.
        let success = response["success"] as? Bool == true
        let data = response["data"] as? [String: Any]
        if success {
            switch kind {
            case .models, .prompt, .command, .setting, .sessionChange: clearStateTimeout()
            case .catalog, .history, .state: break // Gateway-local reads or a state snapshot validated below.
            }
        }
        if case .setting = kind {
            finishSetting(id: id, error: success ? nil : response["error"] as? String ?? "设置失败")
            return
        }
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
            case .sessionChange:
                _ = conversation.resolveSessionChange(id: id, success: false)
                if continueQueuedSession() { return }
                refreshConversation()
            case .history, .state:
                guard conversation.failRequest(id: id) else { return }
            default: break
            }
            recordRequestError(response["error"] as? String ?? "请求失败", for: kind)
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
        case .prompt: return
        case .sessionChange(let destination):
            finishRequest(id)
            let cancelled = data?["cancelled"] as? Bool == true
            let changed = conversation.resolveSessionChange(id: id, success: true, cancelled: cancelled)
            if continueQueuedSession() { return }
            if changed {
                actionError = nil
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
                actionError = "切换会话已取消"
                refreshConversation()
            }
        case .state(let refreshHistory, let requestedPromptIDs):
            guard let data, let streaming = data["isStreaming"] as? Bool else {
                requestFailed(id: id, message: "状态响应无效", outcomeUnknown: false)
                return
            }
            finishRequest(id)
            stateReadError = nil
            let path = data["sessionFile"] as? String
            let running = streaming || data["isCompacting"] as? Bool == true || (data["pendingMessageCount"] as? Int ?? 0) > 0
            let recoveringChangeID = conversation.pendingChange?.id
            let previousHistoryID = conversation.pendingHistoryID
            let appliesToTranscript = conversation.receiveState(id: id, path: path, running: running,
                messageCount: data["messageCount"] as? Int, sessionBarrier: data["sessionBarrier"] as? Bool == true,
                sessionBarrierID: data["sessionBarrierId"] as? String)
            if let previousHistoryID, conversation.pendingHistoryID != previousHistoryID {
                finishRequest(previousHistoryID)
                historyReadError = nil
            }
            guard conversation.pendingChange == nil else { return }
            if let recoveringChangeID {
                finishRequest(recoveringChangeID)
                actionError = nil
            }
            applyModelState(data)
            if settingInFlight == nil, continueQueuedSession() { return }
            guard appliesToTranscript else { publishConversation(); return }
            if conversation.canSend, path == conversation.sessionPath, !requestedPromptIDs.isEmpty,
               let receipts = data["promptReceipts"] as? [[String: Any]] {
                for object in receipts.prefix(ConversationState.promptReceiptLimit) {
                    guard let receipt = PromptReceipt(object), requestedPromptIDs.contains(receipt.id) else { continue }
                    applyPromptReceipt(receipt)
                }
            }
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
            historyReadError = nil
            if !wasReady { requestState() }
        case .command, .setting:
            finishRequest(id)
        }
        publishConversation()
    }

    private func applyModelState(_ data: [String: Any]) {
        let model = data["model"] as? [String: Any]
        let modelID = (model?["id"] as? String) ?? (model?["modelId"] as? String)
        let fullID = (model?["provider"] as? String).flatMap { provider in modelID.map { "\(provider)/\($0)" } }
        let level = data["thinkingLevel"] as? String
        if let pending = settingInFlight {
            guard recoveringSetting else { return }
            let matchesIntent: Bool
            switch pending.change {
            case .model(let option): matchesIntent = fullID == option.id
            case .thinking(let value): matchesIntent = level == value
            }
            // Updated gateways wait for the actual Pi mutation. For earlier ones,
            // require a matching readback: reconnecting does not finish a Mac write.
            let barrier = data["settingBarrierId"] as? String
            guard barrier == pending.id || (barrier == nil && matchesIntent) else { return }
            finishRequest(pending.id)
            settingInFlight = nil
            recoveringSetting = false
            settingError = nil
        }
        if let fullID { confirmedModel = fullID }
        if let level { confirmedThinking = level }
        publishSettings()
    }

    private func clearStateTimeout() {
        if case .timedOut? = stateReadError { stateReadError = nil }
    }

    private func apply(_ event: [String: Any]) {
        // RelayClient only delivers decrypted Pi events. Keep the snapshot ID for readback.
        clearStateTimeout()
        if let id = conversation.pendingStateID { deadlines.removeValue(forKey: id)?.cancel() }
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
        if conversationID != conversation.conversationID {
            conversationID = conversation.conversationID
            promptError = nil
        }
        for (id, receipt) in deferredPromptReceipts {
            if conversation.canSend || !conversation.hasPendingPrompt(id: id) {
                deferredPromptReceipts.removeValue(forKey: id)
                applyPromptReceipt(receipt)
            }
        }
        let unknown = Set(conversation.unconfirmedPromptIDs)
        dismissedPromptIDs.formIntersection(unknown)
        let count = unknown.subtracting(dismissedPromptIDs).count
        let notice = conversation.canSend && count > 0 ? "正在等待 Mac 确认 \(count) 条消息，请勿重复发送。" : nil
        if unconfirmedPromptNotice != notice { unconfirmedPromptNotice = notice }
        if runPhase != conversation.runPhase { runPhase = conversation.runPhase }
        if messages != conversation.messages { messages = conversation.messages }
        if selectedSessionPath != conversation.sessionPath {
            selectedSessionPath = conversation.sessionPath
            if let path = conversation.sessionPath { selectedSessionTitle = sessionTitle(for: path) }
        }
        if isLoadingHistory != conversation.isLoadingHistory { isLoadingHistory = conversation.isLoadingHistory }
        let ready = client.isConnected && conversation.canSend && settingInFlight == nil && queuedSession == nil
        if canSend != ready { canSend = ready }
        if client.isConnected {
            let state: ConnectionState = conversation.isRunning || client.state == .running ? .running : .paired
            if connection != state { connection = state }
        }
        syncLive()
    }

    private func markSettingUncertain() {
        guard settingInFlight != nil else { return }
        settingQueue.removeAll()
        queuedSession = nil
        recoveringSetting = true
        settingError = "正在核对 Mac 上的模型设置。长时间等待时，请检查 Mac 网关版本。"
        publishSettings()
    }

    private func apply(connectionState state: ConnectionState, error: String?) {
        let connected = state == .paired || state == .running
        let newlyConnected = connected && !transportConnected
        if transportConnected && !connected { transportGeneration += 1 }
        transportConnected = connected
        connectionError = state == .error ? (error ?? "连接出错") : nil
        if !connected {
            stateReadError = nil
            historyReadError = nil
            conversation.disconnected()
            queuedSession = nil
            markSettingUncertain()
            cancelRequests(keepingMutations: true)
            if conversation.pendingChange != nil { actionError = "连接中断时会话切换尚未确认，已保留原会话并暂停发送" }
            connection = state
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

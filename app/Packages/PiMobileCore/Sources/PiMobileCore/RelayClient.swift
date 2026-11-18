import Foundation
import Combine

@MainActor
public final class RelayClient: ObservableObject {
    @Published public private(set) var state: ConnectionState = .idle {
        didSet { onConnectionChange?(state, lastError) }
    }
    @Published public private(set) var lastError: String?

    /// Runs on the main actor after both socket state and its error are committed.
    public var onConnectionChange: ((ConnectionState, String?) -> Void)?
    public var onActionError: ((String) -> Void)?

    public var onEvent: (([String: Any]) -> Void)?
    public var onResponse: (([String: Any]) -> Void)?
    public var onPaired: ((String) -> Void)?
    public var onDeviceStatus: ((Bool) -> Void)?
    public var onSessionList: (([[String: Any]]) -> Void)?

    public var isConnected: Bool { state == .paired || state == .running }

    public var hasPairing: Bool { store.restore() != nil }

    private enum Handshake {
        case pair(PairingLink)
        case resume(token: String, key: E2EKey)
    }

    private let configuredEndpoint: URL?
    private let store: PairingStore
    private let makeSocket: (URLRequest) -> any RelaySocket
    private var socket: (any RelaySocket)?
    private var receiver: Task<Void, Never>?
    private var handshake: Handshake?
    private var e2e: E2EKey?  // Only set after this socket's handshake completes.
    private var reconnectDelay: UInt64 = 1_000_000_000
    private var retry: Task<Void, Never>?
    private var isForeground = true
    private let pongTimeout: Duration
    private let heartbeatInterval: Duration
    private var heartbeat: Task<Void, Never>?
    private var probeID: UUID?

    public convenience init(endpoint: String? = nil) {
        self.init(endpoint: endpoint, store: .keychain, makeSocket: Self.webSocket)
    }

    static func webSocket(for request: URLRequest) -> URLSessionWebSocketTask {
        let task = RelaySession.shared.webSocketTask(with: request)
        // The relay accepts 12 MiB frames, including encrypted history with photos.
        task.maximumMessageSize = 12 * 1024 * 1024
        return task
    }

    /// Probe the existing stream on return. A healthy socket keeps its in-flight work.
    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        cancelHeartbeat()
        if foreground { probeSocket() }
    }

    init(endpoint: String?, store: PairingStore, pongTimeout: Duration = .seconds(8),
         heartbeatInterval: Duration = .seconds(20), makeSocket: @escaping (URLRequest) -> any RelaySocket) {
        self.configuredEndpoint = endpoint.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
        self.store = store
        self.makeSocket = makeSocket
        self.pongTimeout = pongTimeout
        self.heartbeatInterval = heartbeatInterval
    }

    private func cancelHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        probeID = nil
    }

    private func scheduleHeartbeat() {
        cancelHeartbeat()
        guard isForeground, let socket, e2e != nil else { return }
        heartbeat = Task { [weak self, weak socket, heartbeatInterval] in
            do { try await Task.sleep(for: heartbeatInterval) } catch { return }
            guard let self, let socket, self.socket === socket else { return }
            self.probeSocket()
        }
    }

    private func probeSocket() {
        guard isForeground, let socket, e2e != nil, probeID == nil else { return }
        heartbeat?.cancel()
        let id = UUID()
        probeID = id
        heartbeat = Task { [weak self, weak socket, pongTimeout] in
            do { try await Task.sleep(for: pongTimeout) } catch { return }
            guard let self, let socket, self.probeID == id else { return }
            self.transportLost(on: socket, message: "连接中断，正在重新连接…")
        }
        socket.ping { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket, self.probeID == id else { return }
                if let error { self.transportLost(on: socket, message: error.localizedDescription) }
                else { self.scheduleHeartbeat() }
            }
        }
    }

    public func connect() {
        disconnect()
        guard let saved = store.restore() else {
            fail(PairingLink.Failure.missingRelay.localizedDescription)
            return
        }
        handshake = .resume(token: saved.token, key: saved.key)
        open(endpoint: saved.endpoint, authorization: saved.token)
    }

    /// 仅在尚未建连时重连，避免 scenePhase 反复触发时踢掉自己。
    public func connectIfNeeded() {
        guard !isConnected, state != .connecting else { return }
        connect()
    }

    public func pair(token: String) {
        let link: PairingLink
        do { link = try PairingLink(token, knownEndpoint: configuredEndpoint ?? store.restore()?.endpoint) }
        catch {
            if isConnected { onActionError?(error.localizedDescription) }
            else { fail(error.localizedDescription) }
            return
        }
        disconnect()
        handshake = .pair(link)
        open(endpoint: link.endpoint, authorization: nil)
    }

    public func resetPairing() {
        disconnect()
        store.clear()
        lastError = nil
    }

    public func send(_ object: [String: Any]) async throws {
        guard let socket, e2e != nil else { throw ClientError.notConnected }
        var wire = object
        if let type = object["type"] as? String, type == "rpc" || type == "extension_ui_response" {
            let payload: [String: Any] = type == "rpc" ? ["command": object["command"] as Any] : object
            guard let sealed = e2e?.seal(payload) else { throw ClientError.missingKey }
            wire = ["type": type, "id": object["id"] as Any, "sealed": sealed]
        }
        try await sendWire(wire, on: socket)
    }

    private func sendWire(_ object: [String: Any], on task: any RelaySocket) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func requestSessions() {
        Task { try? await send(["type": "session_list"]) }
    }

    public func switchSession(path: String) {
        Task { try? await send(["type": "session_switch", "sessionPath": path]) }
    }

    public func newSession() {
        Task { try? await send(["type": "session_new"]) }
    }

    public func disconnect() {
        retry?.cancel()
        retry = nil
        closeSocket()
        lastError = nil
        state = .idle
    }

    private func closeSocket() {
        cancelHeartbeat()
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        handshake = nil
        e2e = nil
    }

    private func transportLost(on task: any RelaySocket, message: String) {
        guard socket === task else { return }
        // A fresh QR is single-use. Only a saved pairing can resume automatically.
        if case .pair = handshake { fail(message); return }
        closeSocket()
        lastError = message
        state = .error
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, 30_000_000_000)
        retry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled, self.isForeground, self.socket == nil else { return }
            self.connect()
        }
    }

    private func fail(_ message: String) {
        disconnect()
        lastError = message
        state = .error
    }

    private func open(endpoint: URL, authorization: String?) {
        var request = URLRequest(url: endpoint)
        if let token = authorization {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        lastError = nil
        state = .connecting
        let task = makeSocket(request)
        socket = task
        task.resume()
        receiver = Task { [weak self] in
            guard let self, !Task.isCancelled, self.socket === task else { return }
            if case let .pair(link) = self.handshake {
                do { try await self.sendWire(["type": "pair", "token": link.code, "pub": link.key.publicKey], on: task) }
                catch {
                    if self.socket === task { self.fail(error.localizedDescription) }
                    return
                }
            }
            await self.receiveLoop(task)
        }
    }

    private func receiveLoop(_ task: any RelaySocket) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled, socket === task else { return }
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                await handle(object, from: task)
            } catch {
                guard !Task.isCancelled, socket === task else { return }
                transportLost(on: task, message: error.localizedDescription)
                return
            }
        }
    }

    private func finishHandshake(token: String?, on task: any RelaySocket) async {
        guard socket === task, let handshake else { return }
        guard let token, PairingLink.isHex(token, length: 64) else {
            fail("中继返回的配对凭据无效")
            return
        }
        let key: E2EKey
        switch handshake {
        case .pair(let link): key = link.key
        case .resume(let expected, let savedKey):
            guard token == expected else { fail("中继返回了不同的配对凭据"); return }
            key = savedKey
        }
        // A restarted gateway needs the same public key again for its E2E handshake.
        do { try await sendWire(["type": "pair_pub", "pub": key.publicKey], on: task) }
        catch {
            transportLost(on: task, message: error.localizedDescription)
            return
        }
        guard socket === task, !Task.isCancelled else { return }
        if case .pair(let link) = handshake, !store.save(endpoint: link.endpoint, token: token, key: key) {
            fail("无法保存配对凭据，请重新配对")
            return
        }
        self.handshake = nil
        e2e = key
        lastError = nil
        state = .paired
        reconnectDelay = 1_000_000_000
        scheduleHeartbeat()
        onPaired?(token)
    }

    func handle(_ object: [String: Any]) async {
        guard let socket else { return }
        await handle(object, from: socket)
    }

    private func handle(_ object: [String: Any], from task: any RelaySocket) async {
        guard socket === task, let type = object["type"] as? String else { return }
        if type == "paired" {
            await finishHandshake(token: object["deviceToken"] as? String, on: task)
            return
        }
        if type == "error", handshake != nil {
            fail(object["message"] as? String ?? "配对失败")
            return
        }
        guard e2e != nil else { return }
        switch type {
        case "status":
            if object["needsPairingKey"] as? Bool == true, let key = e2e {
                // Only the upstream socket changed. Reuse the paired phone socket and
                // send its key before the app's read-only recovery requests.
                do { try await sendWire(["type": "pair_pub", "pub": key.publicKey], on: task) }
                catch { transportLost(on: task, message: error.localizedDescription); return }
                guard socket === task else { return }
                if state == .error {
                    lastError = nil
                    state = .paired
                }
                return
            }
            if (object["state"] as? String) == "unknown" {
                lastError = "Mac gateway 离线"
                state = .error
            } else if let status = object["state"] as? String, ["idle", "running", "paired"].contains(status) {
                lastError = nil
                state = status == "running" ? .running : .paired
            }
        case "event":
            guard let sealed = object["sealed"] as? String, let event = e2e?.open(sealed) else { return }
            recoverFromAuthenticatedTraffic()
            onEvent?(event)
        case "rpc_response":
            guard let sealed = object["sealed"] as? String, let response = e2e?.open(sealed) else { return }
            recoverFromAuthenticatedTraffic()
            onResponse?(response)
        case "device_status":
            onDeviceStatus?(object["online"] as? Bool == true)
        case "session_list":
            onSessionList?(object["sessions"] as? [[String: Any]] ?? [])
        case "error":
            let message = object["message"] as? String ?? "连接出错"
            if message == "gateway offline" || message == "not paired" || message.contains("配对") || message.contains("密钥") {
                lastError = message == "gateway offline" ? "Mac gateway 离线" : message
                state = .error
            } else {
                onActionError?(message)
            }
        default:
            break
        }
    }

    // Older relays may deliver the first real reply without a fresh presence frame.
    private func recoverFromAuthenticatedTraffic() {
        guard state == .error || lastError != nil else { return }
        lastError = nil
        state = .paired
    }

    public enum ClientError: Error {
        case notConnected, missingKey
    }
}

@MainActor
protocol RelaySocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping(_ completion: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: RelaySocket {
    func ping(_ completion: @escaping @Sendable (Error?) -> Void) {
        sendPing(pongReceiveHandler: completion)
    }
}

private final class RelaySession: NSObject, URLSessionTaskDelegate {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RelaySession(), delegateQueue: nil)
    }()

    // Both the bearer and the first pairing frame belong to exactly one origin.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PairingStore {
    let read: () -> String?
    let write: (String) -> Bool
    let clear: () -> Void

    private static let recordKey = "pi-mobile.pairing.v1"
    static let keychain = accounts(
        legacyEndpoint: Bundle.main.object(forInfoDictionaryKey: "PiMobileLegacyRelayEndpoint") as? String,
        read: KeychainStore.read, write: KeychainStore.write, insert: KeychainStore.insert,
        delete: { KeychainStore.delete($0) }
    )

    static func accounts(legacyEndpoint: String?, read: @escaping (String) -> String?,
                         write: @escaping (String, String) -> Bool, insert: @escaping (String, String) -> Bool,
                         delete: @escaping (String) -> Void) -> PairingStore {
        PairingStore(read: {
            if let current = read(recordKey) { return current }
            // The old build stored no origin. Only its fixed relay, supplied by the signer, can own these credentials.
            guard let legacyEndpoint, let endpoint = URL(string: legacyEndpoint, encodingInvalidCharacters: false),
                  PairingLink.isClientEndpoint(endpoint),
                  let token = read("pi-mobile.deviceToken"), PairingLink.isHex(token, length: 64),
                  let privateKey = read("pi-mobile.e2ePriv"), let gatewayKey = read("pi-mobile.gatewayPub"),
                  let key = E2EKey(privateKeyBase64Url: privateKey, gatewayPublicKey: gatewayKey),
                  let text = Record(endpoint: endpoint, token: token, privateKey: key.privateRaw, gatewayKey: key.gatewayPublic).encoded()
            else { return nil }
            // Add only: an unreadable or concurrently created current pairing must never be replaced.
            _ = insert(text, recordKey)
            return read(recordKey)
        }, write: { write($0, recordKey) }, clear: {
            for key in [recordKey, "pi-mobile.deviceToken", "pi-mobile.e2ePriv", "pi-mobile.gatewayPub"] {
                delete(key)
            }
        })
    }

    private struct Record: Codable {
        let endpoint: URL
        let token: String
        let privateKey: String
        let gatewayKey: String

        func encoded() -> String? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func restore() -> (endpoint: URL, token: String, key: E2EKey)? {
        guard let text = read(), let record = try? JSONDecoder().decode(Record.self, from: Data(text.utf8)),
              PairingLink.isClientEndpoint(record.endpoint), PairingLink.isHex(record.token, length: 64),
              let key = E2EKey(privateKeyBase64Url: record.privateKey, gatewayPublicKey: record.gatewayKey) else { return nil }
        return (record.endpoint, record.token, key)
    }

    func save(endpoint: URL, token: String, key: E2EKey) -> Bool {
        let record = Record(endpoint: endpoint, token: token, privateKey: key.privateRaw, gatewayKey: key.gatewayPublic)
        guard let text = record.encoded() else { return false }
        return write(text)
    }
}

import Foundation

public enum ChatRole: String, Sendable, Equatable {
    case user, assistant, tool
}

public enum RunPhase: String, Equatable, Sendable {
    case waiting, thinking, preparingTool = "preparing_tool", replying
}

public enum ToolStatus: Equatable, Sendable {
    case running, finished, failed, unconfirmed
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var text: String
    public var streaming: Bool
    public var toolTitle: String?
    public var sourceID: String?
    public var toolCallID: String?
    public var toolStatus: ToolStatus
    public var toolUpdates: Int = 0
    public var toolDurationMs: Int?
    public var attachments: [ChatPhotoAttachment]

    public init(id: UUID = UUID(), role: ChatRole, text: String, streaming: Bool = false, toolTitle: String? = nil, sourceID: String? = nil, toolCallID: String? = nil, toolStatus: ToolStatus = .finished, attachments: [ChatPhotoAttachment] = []) {
        self.toolStatus = toolStatus
        self.attachments = attachments
        self.id = id
        self.role = role
        self.text = text
        self.streaming = streaming
        self.toolTitle = toolTitle
        self.sourceID = sourceID
        self.toolCallID = toolCallID
    }
}

public enum ConnectionState: String, Sendable, Equatable {
    case idle, connecting, paired, running, error
}

public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let method: String
    public let title: String
    public let detail: String?

    public init(id: String, method: String, title: String, detail: String?) {
        self.id = id
        self.method = method
        self.title = title
        self.detail = detail
    }
}

public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let modelId: String
    public var displayName: String

    public init(provider: String, modelId: String, displayName: String? = nil) {
        self.provider = provider
        self.modelId = modelId
        self.id = "\(provider)/\(modelId)"
        self.displayName = displayName ?? self.id
    }
}

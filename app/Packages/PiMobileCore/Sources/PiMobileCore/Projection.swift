import Foundation

/// 把 pi RPC 的 JSON 事件投影成手机端消息。纯函数，便于单测。
public enum PiProjection {
    public static func text(fromContent content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else {
            return (content as? String) ?? ""
        }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    /// 返回需要追加到当前流式消息的增量与工具卡标题（二选一或都为空）。
    public static func delta(from event: [String: Any]) -> (text: String?, tool: String?) {
        guard let update = event["assistantMessageEvent"] as? [String: Any],
              let type = update["type"] as? String else { return (nil, nil) }
        switch type {
        case "text_delta":
            return (update["delta"] as? String, nil)
        case "thinking_delta":
            guard let piece = update["delta"] as? String else { return (nil, nil) }
            return ("思考：\(piece)", nil)
        case "toolcall_start":
            let name = update["toolName"] as? String ?? "工具"
            return (nil, name)
        default:
            return (nil, nil)
        }
    }

    public static func approval(from event: [String: Any]) -> ApprovalRequest? {
        guard event["type"] as? String == "extension_ui_request",
              let id = event["id"] as? String,
              let method = event["method"] as? String,
              ["confirm", "select", "input", "editor"].contains(method) else { return nil }
        return ApprovalRequest(
            id: id,
            method: method,
            title: event["title"] as? String ?? "需要你的确认",
            detail: event["message"] as? String
        )
    }

    public static func modelOptions(from data: Any?) -> [ModelOption] {
        guard let root = data as? [String: Any] else { return [] }
        let candidates = (root["models"] as? [[String: Any]]) ?? (root["availableModels"] as? [[String: Any]]) ?? []
        return candidates.compactMap { item in
            guard let provider = item["provider"] as? String,
                  let modelId = item["id"] as? String ?? item["modelId"] as? String else { return nil }
            let name = item["name"] as? String
            return ModelOption(provider: provider, modelId: modelId, displayName: name)
        }
    }
}

import XCTest
@testable import PiMobileCore

final class ProjectionTests: XCTestCase {
    func testTextExtraction() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "你好"],
            ["type": "thinking", "thinking": "内部"],
            ["type": "text", "text": "世界"],
        ]
        XCTAssertEqual(PiProjection.text(fromContent: content), "你好世界")
    }

    func testDeltaMapping() {
        let delta = PiProjection.delta(from: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "text_delta", "delta": "hi"],
        ])
        XCTAssertEqual(delta.text, "hi")
        let tool = PiProjection.delta(from: [
            "type": "message_update",
            "assistantMessageEvent": ["type": "toolcall_start", "toolName": "bash"],
        ])
        XCTAssertEqual(tool.tool, "bash")
    }

    func testApprovalMapping() {
        let request = PiProjection.approval(from: [
            "type": "extension_ui_request",
            "id": "u-1",
            "method": "confirm",
            "title": "允许执行？",
            "message": "rm -rf /tmp/x",
        ])
        XCTAssertEqual(request?.id, "u-1")
        XCTAssertEqual(request?.detail, "rm -rf /tmp/x")
        XCTAssertNil(PiProjection.approval(from: ["type": "extension_ui_request", "method": "notify"]))
    }

    func testModelOptions() {
        let options = PiProjection.modelOptions(from: [
            "models": [
                ["provider": "magpie", "id": "hy4-flash", "name": "Hy4"],
                ["provider": "openrouter", "modelId": "gpt-5"],
            ],
        ])
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].id, "magpie/hy4-flash")
        XCTAssertEqual(options[1].displayName, "openrouter/gpt-5")
    }
}

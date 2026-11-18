import XCTest
import PiMobileCore

final class SessionCatalogTests: XCTestCase {
    func testGatewayTopicPreservesPunctuationAndUsesMillisecondActivity() throws {
        let json = #"{"path":"/history/team A/one.jsonl","cwd":"/work/pi","mtime":1234567.5,"title":"  Investigate the configuration_read.timeout.jsonl  ","summary":"  检查断线后的重试策略。  "}"#
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entry = try XCTUnwrap(PiSessionEntry(record))

        XCTAssertEqual(entry.title, "Investigate the configuration_read.timeout.jsonl")
        XCTAssertEqual(entry.summary, "检查断线后的重试策略。")
        XCTAssertEqual(entry.path, "/history/team A/one.jsonl")
        XCTAssertEqual(entry.id, entry.path)
        XCTAssertEqual(try XCTUnwrap(entry.modified).timeIntervalSince1970, 1_234.5675, accuracy: 0.000_001)
    }

    func testLegacyTitlesUseAvailableSummaryOrDistinguishableDatesWithinSameFolder() throws {
        let uuid = "1a2b3c4d-1111-2222-3333-444455556666"
        let stem = "2026-11-18T10-20-30-432Z_\(uuid)"
        let withSummary = try XCTUnwrap(PiSessionEntry([
            "path": "/history/a.jsonl", "cwd": "/work/pi", "title": "\(stem).jsonl", "summary": "整理离线重连策略",
        ]))
        XCTAssertEqual(withSummary.title, "整理离线重连策略")
        XCTAssertNil(withSummary.summary)

        let first = try XCTUnwrap(PiSessionEntry([
            "path": "/history/b.jsonl", "cwd": "/work/pi", "title": stem, "mtime": 1_730_000_000_000,
        ]))
        let second = try XCTUnwrap(PiSessionEntry([
            "path": "/history/c.jsonl", "cwd": "/work/pi", "title": "\(stem).jsonl", "mtime": 1_740_000_000_000,
        ]))
        for entry in [first, second] {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertNotEqual(entry.title, "pi")
            XCTAssertFalse(entry.title.contains(uuid))
            XCTAssertNil(entry.summary)
        }
        XCTAssertNotEqual(first.title, second.title)
    }

    func testSummaryIsOptionalAndDoesNotRepeatTheTopic() throws {
        for summary in [NSNull(), "  \n ", "  编译缓存  "] as [Any] {
            let entry = try XCTUnwrap(PiSessionEntry(["path": "/a", "title": "编译缓存", "summary": summary]))
            XCTAssertEqual(entry.title, "编译缓存")
            XCTAssertNil(entry.summary)
        }
    }

    func testSameFolderNamesKeepFullDirectoryIdentityAndContextAfterFiltering() throws {
        let sessions: [[String: Any]] = [
            ["path": "/a", "cwd": "/clients/A/worktrees/mobile", "title": "修正收据", "mtime": 10],
            ["path": "/b", "cwd": "/clients/B/worktrees/mobile", "title": "单点登录", "mtime": 20],
            ["path": "/c", "cwd": "/clients/A/worktrees/mobile/", "title": "字体适配", "mtime": 30],
            ["path": "/d", "cwd": "/clients/A/tools", "title": "本地工具", "mtime": 40],
        ]
        let folders = PiSessionFolder.grouped(sessions)
        XCTAssertEqual(folders.map(\.id), ["/clients/A/tools", "/clients/A/worktrees/mobile", "/clients/B/worktrees/mobile"])
        XCTAssertEqual(folders.map(\.name), ["tools", "mobile", "mobile"])
        XCTAssertEqual(folders.map(\.parentPath), [nil, "/clients/A/worktrees", "/clients/B/worktrees"])
        XCTAssertEqual(folders[1].entries.map(\.path), ["/c", "/a"])

        let filtered = PiSessionFolder.grouped(sessions, matching: "收据")
        XCTAssertEqual(filtered.count, 1)
        let visible = try XCTUnwrap(filtered.first)
        XCTAssertEqual(visible.parentPath, "/clients/A/worktrees")
        XCTAssertEqual(visible.entries.map(\.id), ["/a"])
    }

    func testMostRecentActivityOrdersFoldersAndRowsWithStablePathIdentities() {
        let sessions: [[String: Any]] = [
            ["path": "/one", "cwd": "/stale", "title": "过期副本", "mtime": 5],
            ["path": "/two", "cwd": "/tools", "title": "工具调用", "mtime": 40],
            ["path": "/three", "cwd": "/docs", "title": "缺少时间"],
            ["path": "/one", "cwd": "/docs", "title": "文档更新", "mtime": 50],
            ["path": "/four", "cwd": "/docs", "title": "示例", "mtime": 30],
            ["path": "/five", "cwd": "/docs", "title": "排版", "mtime": 30],
        ]
        let folders = PiSessionFolder.grouped(sessions)
        XCTAssertEqual(folders.map(\.id), ["/docs", "/tools"])
        XCTAssertEqual(folders.first?.entries.map(\.id), ["/one", "/five", "/four", "/three"])
        XCTAssertEqual(folders.first?.entries.first?.title, "文档更新")
        XCTAssertEqual(PiSessionFolder.grouped(sessions.reversed()).flatMap(\.entries).map(\.id),
                       folders.flatMap(\.entries).map(\.id))
    }

    func testFolderSearchIncludesEveryChildAndTopicPreviewOrPathSelectIndividualSessions() {
        let sessions: [[String: Any]] = [
            ["path": "/logs/abc.jsonl", "cwd": "/Teams/Studio/Mobile", "title": "缓存", "summary": "核对 ETag", "mtime": 10],
            ["path": "/logs/xyz.jsonl", "cwd": "/Teams/Studio/Mobile", "title": "更新依赖", "mtime": 20],
            ["path": "/logs/def.jsonl", "cwd": "/Teams/Web", "title": "发布页面", "mtime": 30],
        ]
        let queries: [(String, [String])] = [
            ("  mobile\n", ["/logs/xyz.jsonl", "/logs/abc.jsonl"]),
            ("studio/mobile", ["/logs/xyz.jsonl", "/logs/abc.jsonl"]),
            ("etag", ["/logs/abc.jsonl"]),
            ("依赖", ["/logs/xyz.jsonl"]),
            ("def.jsonl", ["/logs/def.jsonl"]),
            ("未知话题", []),
            (" \n", ["/logs/def.jsonl", "/logs/xyz.jsonl", "/logs/abc.jsonl"]),
        ]
        for (query, paths) in queries {
            XCTAssertEqual(PiSessionFolder.grouped(sessions, matching: query).flatMap(\.entries).map(\.path), paths, query)
        }
    }

    func testOnlyOpenableSessionsAreIncludedAndMissingCWDIsSeparateFromRoot() throws {
        XCTAssertNil(PiSessionEntry(["cwd": "/work", "title": "缺失路径"]))
        XCTAssertNil(PiSessionEntry(["path": " \t"]))
        let folders = PiSessionFolder.grouped([
            ["path": "/unknown", "title": "没有目录", "mtime": "invalid"],
            ["path": "/root", "cwd": "/", "title": "根目录", "mtime": 42],
            ["path": "", "cwd": "/work"],
        ])
        XCTAssertEqual(folders.map(\.id), ["/", ""])
        XCTAssertEqual(folders.map(\.name), ["/", "未指定文件夹"])
        let unknown = try XCTUnwrap(folders.last?.entries.first)
        XCTAssertEqual(unknown.path, "/unknown")
        XCTAssertNil(unknown.modified)
    }
}

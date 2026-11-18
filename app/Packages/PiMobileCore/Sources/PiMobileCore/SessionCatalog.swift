import Foundation

public struct PiSessionEntry: Identifiable {
    public var id: String { path }
    public let path: String
    public let cwd: String
    public let title: String
    public let summary: String?
    public let modified: Date?

    public init?(_ session: [String: Any]) {
        guard let path = session["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.path = path

        // The directory is on the gateway. Strip trailing separators without resolving it on the phone.
        var directory = session["cwd"] as? String ?? ""
        while directory.hasSuffix("/") && directory != "/" { directory.removeLast() }
        cwd = directory
        if let milliseconds = (session["mtime"] as? NSNumber)?.doubleValue, milliseconds.isFinite {
            modified = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            modified = nil
        }

        let topic = (session["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (session["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty && !Self.isLegacyFilename(topic) {
            title = topic
        } else if !preview.isEmpty {
            title = preview
        } else if let modified {
            title = "会话 · \(modified.formatted(date: .abbreviated, time: .shortened))"
        } else {
            title = "未命名会话"
        }
        summary = preview.isEmpty || preview == title ? nil : preview
    }

    private static func isLegacyFilename(_ topic: String) -> Bool {
        // Older gateways sent the ISO/epoch timestamp and UUID from Pi's JSONL filename.
        let stem = topic.hasSuffix(".jsonl") ? topic.dropLast(6) : topic[...]
        guard let separator = stem.lastIndex(of: "_"),
              UUID(uuidString: String(stem.suffix(from: stem.index(after: separator)))) != nil else { return false }
        return stem[..<separator].wholeMatch(of: #/(?:\d{4}-\d{2}-\d{2}T[\d:.+Z-]+|\d{10}(?:\d{3})?)/#) != nil
    }

    fileprivate static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = lhs.modified ?? .distantPast
        let right = rhs.modified ?? .distantPast
        return left == right ? lhs.path < rhs.path : left > right
    }
}

public struct PiSessionFolder: Identifiable {
    public let id: String  // Full working directory, or an empty string if the gateway has none.
    public let name: String
    public let parentPath: String?
    public let entries: [PiSessionEntry]

    public static func grouped(_ sessions: [[String: Any]], matching search: String = "") -> [Self] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let entries = sessions.compactMap(PiSessionEntry.init).sorted(by: PiSessionEntry.newerFirst)
            .filter { seen.insert($0.path).inserted }
        let directories = Dictionary(grouping: entries, by: \.cwd)
        // Disambiguate against every directory, even when the search only matches one of them.
        let directoriesByName = Dictionary(grouping: directories.keys, by: displayName)

        let folders = directories.compactMap { cwd, entries -> Self? in
            let name = displayName(cwd)
            let matchesFolder = query.isEmpty || cwd.localizedStandardContains(query) || name.localizedStandardContains(query)
            let visible = matchesFolder ? entries : entries.filter {
                $0.title.localizedStandardContains(query) || $0.summary?.localizedStandardContains(query) == true
                    || $0.path.localizedStandardContains(query)
            }
            guard !visible.isEmpty else { return nil }
            let needsParent = !cwd.isEmpty && (directoriesByName[name]?.count ?? 0) > 1
            return Self(id: cwd, name: name, parentPath: needsParent ? (cwd as NSString).deletingLastPathComponent : nil,
                        entries: visible)
        }
        return folders.sorted { PiSessionEntry.newerFirst($0.entries[0], $1.entries[0]) }
    }

    private static func displayName(_ cwd: String) -> String {
        cwd.isEmpty ? "未指定文件夹" : (cwd as NSString).lastPathComponent
    }
}

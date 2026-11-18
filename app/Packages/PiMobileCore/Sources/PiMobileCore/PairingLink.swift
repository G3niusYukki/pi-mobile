import Foundation
import Network

struct PairingLink {
    let endpoint: URL
    let code: String
    let key: E2EKey

    init(_ input: String, knownEndpoint: URL? = nil) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment: String
        if input.contains("#") {
            guard var url = Self.components(input, scheme: "https", path: "/pi/pair"),
                  let value = url.percentEncodedFragment else { throw Failure.invalidLink }
            fragment = value
            url.scheme = "wss"
            url.path = "/pi/client"
            url.fragment = nil
            guard let target = url.url else { throw Failure.invalidLink }
            endpoint = target
        } else {
            guard let knownEndpoint, Self.isClientEndpoint(knownEndpoint) else { throw Failure.missingRelay }
            endpoint = knownEndpoint
            fragment = input
        }
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isHex(parts[0], length: 32),
              let key = E2EKey(gatewayPublicKey: String(parts[1])) else { throw Failure.invalidCode }
        code = parts[0].lowercased()
        self.key = key
    }

    static func isClientEndpoint(_ url: URL) -> Bool {
        guard let parts = components(url.absoluteString, scheme: "wss", path: "/pi/client") else { return false }
        return parts.fragment == nil
    }

    static func isHex<S: StringProtocol>(_ value: S, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func components(_ input: String, scheme: String, path: String) -> URLComponents? {
        guard let parts = URLComponents(string: input, encodingInvalidCharacters: false),
              parts.scheme?.lowercased() == scheme, parts.percentEncodedPath == path,
              parts.user == nil, parts.password == nil, parts.query == nil,
              let host = parts.encodedHost, !host.isEmpty else { return nil }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), !host.contains("%"), IPv6Address(String(host.dropFirst().dropLast())) != nil else { return nil }
        } else {
            let label = #"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"#
            guard host.utf8.count <= 254, host.range(of: "^\(label)(?:\\.\(label))*\\.?$", options: .regularExpression) != nil else { return nil }
        }
        // Foundation can return nil for an explicit empty or overflowing port.
        let authority = input.dropFirst(scheme.count + 3).prefix { $0 != "/" }
        let port = parts.port
        guard port.map({ (1...65535).contains($0) }) != false,
              authority == host + (port.map { ":\($0)" } ?? "") else { return nil }
        return parts
    }

    enum Failure: LocalizedError {
        case invalidLink, invalidCode, missingRelay
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "配对链接无效，请扫描或粘贴网关生成的完整 HTTPS 配对链接"
            case .invalidCode: return "配对码或网关公钥无效，请重新扫描配对链接"
            case .missingRelay: return "尚未指定中继，请扫描或粘贴完整 HTTPS 配对链接"
            }
        }
    }
}

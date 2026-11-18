import Foundation
import CryptoKit

/// 与 gateway/src/crypto.mjs 对齐：X25519 + HKDF-SHA256 + AES-GCM。
public struct E2EKey {
    private let symmetric: SymmetricKey
    public let publicKey: String
    let privateRaw: String
    let gatewayPublic: String

    public init?(gatewayPublicKey: String) {
        self.init(privateKey: Curve25519.KeyAgreement.PrivateKey(), gatewayPublicKey: gatewayPublicKey)
    }

    public init?(privateKeyBase64Url: String, gatewayPublicKey: String) {
        guard let raw = Data(base64Url: privateKeyBase64Url), raw.base64UrlEncoded == privateKeyBase64Url,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        self.init(privateKey: privateKey, gatewayPublicKey: gatewayPublicKey)
    }

    private init?(privateKey: Curve25519.KeyAgreement.PrivateKey, gatewayPublicKey: String) {
        guard gatewayPublicKey.utf8.count == 43, let raw = Data(base64Url: gatewayPublicKey),
              raw.base64UrlEncoded == gatewayPublicKey,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        symmetric = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("pi-mobile-e2e-v1".utf8),
            sharedInfo: Data("pi-mobile".utf8),
            outputByteCount: 32
        )
        privateRaw = privateKey.rawRepresentation.base64UrlEncoded
        publicKey = privateKey.publicKey.rawRepresentation.base64UrlEncoded
        gatewayPublic = gatewayPublicKey
    }

    public func seal(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let sealed = try? AES.GCM.seal(data, using: symmetric).combined else { return nil }
        return sealed.base64UrlEncoded
    }

    public func open(_ sealed: String) -> [String: Any]? {
        guard let data = Data(base64Url: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: symmetric),
              let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return object
    }
}

extension Data {
    var base64UrlEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64Url: String) {
        var s = base64Url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: padding)
        self.init(base64Encoded: s)
    }
}

import CryptoKit
import Foundation
import Security

/// The Sign in with Apple nonce: a random string kept in the app, whose SHA256 goes in the Apple request.
/// Apple puts the hash in the identity token, and Supabase checks it against the raw value it is given.
public struct AppleNonce: Sendable, Equatable {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    /// 32 random characters from `[0-9A-Za-z-.]`: 64 symbols, so each byte's low 6 bits pick one without bias.
    public static func random(length: Int = 32) -> AppleNonce {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return AppleNonce(raw: String(bytes.map { charset[Int($0 & 63)] }))
    }

    /// Lowercase hex SHA256 of `raw`: what `ASAuthorizationAppleIDRequest.nonce` carries.
    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

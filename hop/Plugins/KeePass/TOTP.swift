import CryptoKit
import Foundation

/// RFC 6238 TOTP. Accepts `otpauth://totp/…`, KeeOTP `key=…&step=…&size=…`, or a bare Base32 secret.
nonisolated enum TOTP {
    enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }
    enum TOTPError: Error { case invalid }

    struct Parameters: Equatable, Sendable {
        var secret: Data
        var digits = 6
        var period = 30
        var algorithm: Algorithm = .sha1
    }

    static func parse(_ spec: String) throws -> Parameters {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("otpauth://") {
            guard let comps = URLComponents(string: s) else { throw TOTPError.invalid }
            var p = Parameters(secret: Data())
            for item in comps.queryItems ?? [] {
                let v = item.value ?? ""
                switch item.name.lowercased() {
                case "secret": p.secret = try Base32.decode(v)
                case "digits": p.digits = Int(v) ?? 6
                case "period": p.period = Int(v) ?? 30
                case "algorithm": p.algorithm = Algorithm(rawValue: v.uppercased()) ?? .sha1
                default: break
                }
            }
            guard !p.secret.isEmpty else { throw TOTPError.invalid }
            return p
        }
        if s.contains("key=") {
            var p = Parameters(secret: Data())
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "key": p.secret = try Base32.decode(kv[1].removingPercentEncoding ?? kv[1])
                case "step": p.period = Int(kv[1]) ?? 30
                case "size": p.digits = Int(kv[1]) ?? 6
                case "otphashmode": p.algorithm = Algorithm(rawValue: kv[1].uppercased()) ?? .sha1
                default: break
                }
            }
            guard !p.secret.isEmpty else { throw TOTPError.invalid }
            return p
        }
        return Parameters(secret: try Base32.decode(s))
    }

    static func code(_ spec: String, at date: Date = Date()) throws -> String {
        generate(try parse(spec), at: date)
    }

    static func generate(_ p: Parameters, at date: Date) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(max(1, p.period)))
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: 8)
        let key = SymmetricKey(data: p.secret)
        let mac: [UInt8] = switch p.algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var mod: UInt32 = 1
        for _ in 0..<min(p.digits, 9) { mod *= 10 }
        let value = binary % mod
        return String(format: "%0\(p.digits)u", value)
    }

    /// Seconds left in the current period.
    static func remaining(_ spec: String, at date: Date = Date()) -> Int? {
        guard let p = try? parse(spec) else { return nil }
        return p.period - Int(date.timeIntervalSince1970) % p.period
    }
}

/// RFC 4648 Base32 (case-insensitive, padding and spaces ignored).
nonisolated enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ s: String) throws -> Data {
        var bits: UInt64 = 0, count = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let v = alphabet.firstIndex(of: ch) else { throw TOTP.TOTPError.invalid }
            bits = (bits << 5) | UInt64(v)
            count += 5
            if count >= 8 {
                count -= 8
                out.append(UInt8((bits >> UInt64(count)) & 0xff))
            }
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        var out = "", bits: UInt64 = 0, count = 0
        for b in data {
            bits = (bits << 8) | UInt64(b)
            count += 8
            while count >= 5 {
                count -= 5
                out.append(alphabet[Int((bits >> UInt64(count)) & 31)])
            }
        }
        if count > 0 { out.append(alphabet[Int((bits << UInt64(5 - count)) & 31)]) }
        while out.count % 8 != 0 { out.append("=") }
        return out
    }
}

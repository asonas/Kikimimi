import Foundation
import Security

public enum IDTokenValidator {
    public struct Identity: Sendable, Equatable {
        public let sub: String
        public let email: String
    }

    public static func validate(_ jwt: String, jwks: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Base64URL.decode(parts[0]), let payload = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]) else { throw ChatGPTAuthError.invalidIDToken }
        struct Header: Decodable { let alg: String; let kid: String }
        struct JWK: Decodable { let kty: String; let kid: String; let alg: String?; let n: String; let e: String }
        struct JWKS: Decodable { let keys: [JWK] }
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData), header.alg == "RS256",
              let keys = try? JSONDecoder().decode(JWKS.self, from: jwks),
              let jwk = keys.keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") }),
              let modulus = Base64URL.decode(jwk.n), !modulus.isEmpty,
              let exponent = Base64URL.decode(jwk.e), !exponent.isEmpty else { throw ChatGPTAuthError.invalidIDToken }
        let der = tlv(0x30, integer(modulus) + integer(exponent))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let key = SecKeyCreateWithData(der as CFData, attributes, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else {
            throw ChatGPTAuthError.invalidIDToken
        }
        struct Claims: Decodable {
            let iss: String; let aud: [String]; let exp: Double; let nonce: String?; let sub: String; let email: String
            enum CodingKeys: String, CodingKey { case iss, aud, exp, nonce, sub, email }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                iss = try c.decode(String.self, forKey: .iss)
                if let one = try? c.decode(String.self, forKey: .aud) { aud = [one] }
                else { aud = try c.decode([String].self, forKey: .aud) }
                exp = try c.decode(Double.self, forKey: .exp)
                nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
                sub = try c.decode(String.self, forKey: .sub); email = try c.decode(String.self, forKey: .email)
            }
        }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload), claims.iss == "https://auth.openai.com",
              claims.aud.contains(clientID), claims.exp.isFinite, claims.exp > now.timeIntervalSince1970,
              nonce == nil || claims.nonce == nonce, !claims.sub.isEmpty, !claims.email.isEmpty else {
            throw ChatGPTAuthError.invalidIDToken
        }
        return Identity(sub: claims.sub, email: claims.email)
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes.append(0) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    private static func tlv(_ tag: UInt8, _ data: Data) -> Data {
        var length = Data()
        if data.count < 128 { length.append(UInt8(data.count)) }
        else {
            var count = data.count
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag]) + length + data
    }
}

import Foundation
import CryptoKit
import Security

enum SafeFailure: String, Error {
    case cancelled, timeout, invalidCallback, denied, invalidToken, missingScope, keychain, network
    case loginRequired, models, modelRequired, rateLimit, requestFailed, incomplete, tooLarge, empty
    var message: String {
        switch self {
        case .cancelled: return "취소됨"
        case .timeout: return "시간이 초과됐습니다. 앱으로 돌아와 다시 시도하세요."
        case .invalidCallback: return "로그인 응답을 안전하게 확인하지 못했습니다."
        case .denied: return "로그인이 승인되지 않았습니다."
        case .invalidToken: return "계정 토큰 검증에 실패했습니다. 다시 로그인하세요."
        case .missingScope: return "이 계정은 ChatGPT 플랜 사용 권한을 부여하지 않았습니다."
        case .keychain: return "기기의 안전한 저장소를 사용할 수 없습니다."
        case .network: return "네트워크 연결을 확인하세요."
        case .loginRequired: return "설정에서 ChatGPT 로그인이 필요합니다."
        case .models: return "사용 가능한 모델 목록을 확인하지 못했습니다."
        case .modelRequired: return "설정에서 사용 가능한 모델을 선택하세요."
        case .rateLimit: return "사용량 한도 또는 요청 제한입니다. 잠시 후 다시 시도하세요."
        case .requestFailed: return "요청이 완료되지 않았습니다. 계정·모델·연결을 확인하세요."
        case .incomplete: return "응답이 끝까지 도착하지 않았습니다. 다시 전송하세요."
        case .tooLarge: return "입력이 너무 큽니다. 더 짧은 글 또는 작은 사진을 사용하세요."
        case .empty: return "보낼 내용 또는 최종 답이 없습니다."
        }
    }
}

enum OAuthContract {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let tokenURL = URL(string: issuer + "/api/accounts/oauth/token")!
    static let jwksURL = URL(string: issuer + "/.well-known/jwks.json")!
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SafeFailure.invalidToken }
        return base64url(Data(bytes))
    }
    static func authorization(transaction: LoginTransaction, host: String) throws -> URL {
        var url = URLComponents(string: issuer + "/api/accounts/authorize")!
        url.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: transaction.existingClient ?? "dynamic_agent_client"),
            URLQueryItem(name: "redirect_uri", value: transaction.redirect),
            URLQueryItem(name: "scope", value: scopes), URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: transaction.state), URLQueryItem(name: "nonce", value: transaction.nonce),
            URLQueryItem(name: "code_challenge", value: base64url(Data(SHA256.hash(data: Data(transaction.verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "ext_agent_host_id", value: host)
        ]
        if transaction.existingClient == nil { url.queryItems?.append(URLQueryItem(name: "agent_name_hint", value: "공학용 계산기")) }
        guard let result = url.url else { throw SafeFailure.invalidToken }; return result
    }
    static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

struct LoginTransaction {
    let state: String
    let nonce: String
    let verifier: String
    let redirect: String
    let existingClient: String?
    init(port: UInt16, existingClient: String? = nil) throws {
        state = try OAuthContract.random(); nonce = try OAuthContract.random(); verifier = try OAuthContract.random()
        redirect = "http://127.0.0.1:\(port)/auth/callback"; self.existingClient = existingClient
    }
}

struct AuthorizationCode {
    let code: String
    let clientID: String
    static func parse(_ target: String, transaction: LoginTransaction) throws -> AuthorizationCode {
        guard target.utf8.count < 8192, target.hasPrefix("/auth/callback?"),
              let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/auth/callback",
              url.fragment == nil else { throw SafeFailure.invalidCallback }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw SafeFailure.invalidCallback }
            query[item.name] = value
        }
        guard query["state"] == transaction.state else { throw SafeFailure.invalidCallback }
        if query["error"] != nil { throw SafeFailure.denied }
        guard let code = query["code"], !code.isEmpty, code.count < 4096,
              let client = query["client_id"] ?? transaction.existingClient,
              client.hasPrefix("oaiapp_"), client.count < 256,
              transaction.existingClient == nil || client == transaction.existingClient else { throw SafeFailure.invalidCallback }
        return AuthorizationCode(code: code, clientID: client)
    }
}

enum LoopbackRequest {
    static func target(_ data: Data, port: UInt16) -> String? {
        guard data.count <= 8192, let request = String(data: data, encoding: .utf8),
              request.hasSuffix("\r\n\r\n") else { return nil }
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/auth/callback?"), !first[1].contains("#") else { return nil }
        var hosts: [String] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host" { hosts.append(value) }
            if name == "transfer-encoding" || name == "content-length" { return nil }
        }
        guard hosts == ["127.0.0.1:\(port)"] else { return nil }
        return String(first[1])
    }
}

struct TokenReply: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double?
    let token_type: String?
    let scope: String?
}

struct AccountRecord: Codable, Identifiable {
    var id: String { subject + "|" + clientID }
    var subject: String
    var clientID: String
    var label: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    var model: String?
    var usageAcknowledged = false
}

struct ModelOption: Decodable, Identifiable {
    var id: String { slug }
    let slug: String
    let display_name: String
    let visibility: String?
}
struct ModelCatalog: Decodable { let models: [ModelOption] }

struct JWKSet: Decodable {
    struct Key: Decodable { let kty: String; let kid: String; let n: String?; let e: String?; let alg: String?; let use: String? }
    let keys: [Key]
}

enum IDTokenVerifier {
    struct Identity { let subject: String; let label: String }
    private static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var n = count, bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 } while n > 0
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func integer(_ input: Data) -> Data {
        var bytes = Data(input.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + bytes
    }
    static func verify(_ jwt: String, keys: JWKSet, audience: String, nonce: String?, subject: String? = nil, now: Date = Date()) throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard jwt.count < 32768, parts.count == 3,
              let headerData = OAuthContract.decode(parts[0]), let payloadData = OAuthContract.decode(parts[1]),
              let signature = OAuthContract.decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              header["crit"] == nil,
              let jwk = keys.keys.first(where: { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let n = jwk.n.flatMap(OAuthContract.decode), let e = jwk.e.flatMap(OAuthContract.decode),
              n.count >= 256, n.count <= 512, e.count <= 8 else { throw SafeFailure.invalidToken }
        let inner = integer(n) + integer(e), der = Data([0x30]) + derLength(inner.count) + inner
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              claims["iss"] as? String == OAuthContract.issuer,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 60,
              subject == nil || subject == sub,
              nonce == nil || claims["nonce"] as? String == nonce else { throw SafeFailure.invalidToken }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(audience),
              audiences.count <= 1 || claims["azp"] as? String == audience else { throw SafeFailure.invalidToken }
        if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 + 60 { throw SafeFailure.invalidToken }
        let label = (claims["email"] as? String) ?? (claims["name"] as? String) ?? "ChatGPT 계정"
        return Identity(subject: sub, label: String(label.prefix(160)))
    }
}

struct ResponseStream {
    private var eventLines: [String] = []
    private var accumulated = ""
    private(set) var answer: String?
    private var complete = false
    mutating func receive(_ line: String) throws {
        guard line.utf8.count <= 2_000_000 else { throw SafeFailure.tooLarge }
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix("data:") { eventLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
    }
    private mutating func dispatch() throws {
        guard !eventLines.isEmpty else { return }
        let data = eventLines.joined(separator: "\n"); eventLines.removeAll(keepingCapacity: true)
        if data == "[DONE]" { return }
        guard let bytes = data.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = event["type"] as? String else { throw SafeFailure.incomplete }
        switch type {
        case "response.output_text.delta":
            guard !complete else { throw SafeFailure.incomplete }
            accumulated += event["delta"] as? String ?? ""
            guard accumulated.utf8.count < 256_000 else { throw SafeFailure.tooLarge }
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else { throw SafeFailure.incomplete }
            var final: [String] = []
            for item in response["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text", let text = content["text"] as? String { final.append(text) }
                    if content["type"] as? String == "refusal" { throw SafeFailure.requestFailed }
                }
            }
            let text = (final.isEmpty ? accumulated : final.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count < 256_000 else { throw SafeFailure.empty }
            answer = text; complete = true
        case "error", "response.failed", "response.incomplete": throw SafeFailure.requestFailed
        default: break
        }
    }
    mutating func finish() throws -> String {
        try dispatch()
        guard complete, let answer else { throw SafeFailure.incomplete }; return answer
    }
}

struct AIInput {
    let text: String
    let image: Data?
    let imageType: String?
    var content: [[String: Any]] {
        var result: [[String: Any]] = []
        if !text.isEmpty { result.append(["type": "input_text", "text": text]) }
        if let image { result.append(["type": "input_image", "image_url": "data:\(imageType ?? "image/png");base64,\(image.base64EncodedString())", "detail": "high"]) }
        return result
    }
}

enum ResponseRequest {
    static func data(model: String, input: AIInput) throws -> Data {
        guard !input.text.isEmpty || input.image != nil else { throw SafeFailure.empty }
        guard input.text.utf8.count <= 32_000, (input.image?.count ?? 0) <= 8_000_000 else { throw SafeFailure.tooLarge }
        return try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "instructions": "수학·과학 문제를 풀고 최종 답만 출력하세요. 풀이 과정이나 인사말은 생략하세요. 수식은 LaTeX \\( \\) 또는 \\[ \\]로 표현하세요. 서로 다른 답은 줄바꿈으로 구분하고, 하나의 수식은 가능한 한 한 줄로 표현하세요. 이미지를 읽을 수 없거나 정보가 부족하면 추측하지 말고 짧게 밝혀주세요.",
            "input": [["role": "user", "content": input.content]]
        ])
    }
}

import Foundation
import Security
import CryptoKit

@main enum CoreChecks {
    static var passed = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { fatalError("CHECK FAILED: " + label) }; passed += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("CHECK FAILED (accepted): " + label) } catch { passed += 1 }
    }
    static func engine(_ keys: [String]) -> ScientificEngine { var e = ScientificEngine(); keys.forEach { e.press($0) }; return e }
    static func near(_ keys: [String], _ expected: Double) {
        check(abs(NSDecimalNumber(decimal: engine(keys).value).doubleValue - expected) < 1e-10, keys.joined(separator: " "))
    }
    @MainActor static func main() async throws {
        check(engine(["0", ".", "1", "+", "0", ".", "2", "="]).display == "0.3", "exact decimal")
        check(engine(["2", "+", "3", "=", "="]).value == 8, "repeat equals")
        check(engine(["2", "+", "3", "×", "4", "="]).value == 20, "immediate execution parity")
        check(engine(["2", "+", "3", "C", "4", "="]).value == 4, "clear operator")
        check(engine(["1", "2", "⌫"]).value == 1, "backspace")
        check(engine(["1", ".", ".", "5"]).entry == "1.5", "one decimal point")
        check(engine(["5", "±", "±"]).value == 5, "sign twice")
        check(engine(["5", "MS", "C", "MR"]).value == 5, "C preserves memory")
        check(engine(["5", "MS", "2", "M+", "MR"]).value == 7, "memory addition")
        check(engine(["5", "MS", "2", "M−", "MR"]).value == 3, "memory subtraction")
        check(!engine(["5", "MS", "MC"]).hasMemory, "memory clear")
        check(engine(["2", "0", "0", "+", "1", "0", "%", "="]).value == 220, "additive percentage")
        near(["5", "0", "%"], 0.5)
        near(["3", "0", "sin"], 0.5); near(["6", "0", "cos"], 0.5); near(["4", "5", "tan"], 1)
        near(["9", "0", "cos"], 0); near(["π", "DEG", "sin"], 0)
        check(engine(["9", "0", "tan"]).display == "정의되지 않음", "tan domain")
        near(["1", "0", "0", "log"], 2); near(["e", "ln"], 1)
        near(["2", "10ˣ"], 100); near(["0", "eˣ"], 1)
        near(["9", "√x"], 3); near(["4", "1/x"], 0.25)
        near(["5", "x²"], 25); near(["5", "x³"], 125); near(["2", "xʸ", "3", "="], 8)
        near(["5", "n!"], 120); near(["0", "n!"], 1)
        near(["5", "±", "|x|"], 5); near(["2", ".", "9", "⌊x⌋"], 2); near(["2", ".", "1", "⌈x⌉"], 3)
        near(["2", ".", "1", "±", "⌊x⌋"], -3); near(["2", ".", "9", "±", "⌈x⌉"], -2)
        near(["7", "mod", "3", "="], 1); near(["7", "±", "mod", "3", "="], -1)
        for keys in [["0", "ln"], ["0", "log"], ["1", "±", "√x"], ["2", ".", "1", "n!"], ["2", "8", "n!"], ["1", "÷", "0", "="]] {
            check(Decimal(string: engine(keys).display) == nil, "domain rejection " + keys.joined())
        }
        var seq = HiddenSequence()
        check(!seq.accept("ln", now: 0), "sequence starts")
        check(!seq.accept("n!", now: 1), "sequence second")
        check(!seq.accept("mod", now: 2), "sequence third")
        check(seq.accept("ln", now: 3), "sequence complete")
        check(!seq.accept("ln", now: 4), "sequence reset")
        check(!seq.accept("n!", now: 9), "sequence timeout")
        check(!seq.accept("mod", now: 10), "sequence timeout cannot complete")
        check(AnswerPages.split("a\nb\nc") == ["a", "b", "c"], "answer pagination")
        check(AnswerPages.split("\\begin{cases}\na & x>0\\\\\nb & x<0\n\\end{cases}").count == 1, "cases atomic")
        check(AnswerPages.split(" \n ").isEmpty, "empty answer")
        check(AnswerPages.split("\\[\n\\frac{1}{x}\n\\]").count == 1, "multiline display math stays atomic")
        check(AnswerPages.split("$$\nx^2\n$$").count == 1, "multiline dollar math stays atomic")
        let tx = try LoginTransaction(port: 34567)
        check(tx.verifier.count >= 43, "PKCE length")
        check(tx.state != tx.nonce && tx.nonce != tx.verifier, "fresh independent state")
        let url = try OAuthContract.authorization(transaction: tx, host: "urn:uuid:synthetic-test-only")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        check(q["client_id"] == "dynamic_agent_client", "registration entrypoint")
        check(q["code_challenge_method"] == "S256", "PKCE S256")
        check(q["redirect_uri"] == tx.redirect, "exact loopback")
        let target = "/auth/callback?state=\(tx.state)&code=synthetic-code&client_id=oaiapp_synthetic"
        check(try AuthorizationCode.parse(target, transaction: tx).clientID == "oaiapp_synthetic", "issued client accepted")
        rejects("wrong state") { _ = try AuthorizationCode.parse(target.replacingOccurrences(of: tx.state, with: "bad"), transaction: tx) }
        rejects("duplicate state") { _ = try AuthorizationCode.parse(target + "&state=bad", transaction: tx) }
        rejects("fragment") { _ = try AuthorizationCode.parse(target + "#bad", transaction: tx) }
        rejects("dynamic client is not issued client") { _ = try AuthorizationCode.parse(target.replacingOccurrences(of: "oaiapp_synthetic", with: "dynamic_agent_client"), transaction: tx) }
        rejects("missing issued client") { _ = try AuthorizationCode.parse("/auth/callback?state=\(tx.state)&code=a", transaction: tx) }
        rejects("denied") { _ = try AuthorizationCode.parse("/auth/callback?state=\(tx.state)&error=access_denied", transaction: tx) }
        let http = Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:34567\r\n\r\n".utf8)
        check(LoopbackRequest.target(http, port: 34567) == target, "strict HTTP callback")
        check(LoopbackRequest.target(http, port: 99) == nil, "wrong port")
        check(LoopbackRequest.target(http + Data("body".utf8), port: 34567) == nil, "body rejected")
        check(LoopbackRequest.target(Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:34567\r\nHost: other\r\n\r\n".utf8), port: 34567) == nil, "duplicate Host")
        check(LoopbackRequest.target(Data("GET \(target) HTTP/1.1\r\nHost: localhost:34567\r\n\r\n".utf8), port: 34567) == nil, "localhost forbidden")
        let form = String(data: OAuthContract.form(["a": "x+y&z=한 글"]), encoding: .utf8)!
        check(form.contains("%2B") && form.contains("%26") && form.contains("%20"), "form encoding")
        try jwtChecks()
        var stream = ResponseStream()
        try stream.receive("data: {\"type\":\"response.output_text.delta\",\"delta\":\"5\"}"); try stream.receive("")
        rejects("partial delta is not final") { _ = try stream.finish() }
        try stream.receive("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"5\"}]}]}}")
        try stream.receive(""); check(try stream.finish() == "5", "final completed response")
        var failed = ResponseStream()
        rejects("failed event") { try failed.receive("data: {\"type\":\"response.failed\"}"); try failed.receive("") }
        let body = try JSONSerialization.jsonObject(with: ResponseRequest.data(model: "synthetic-model", input: AIInput(text: "2+3", image: nil, imageType: nil))) as! [String: Any]
        check(body["store"] as? Bool == false && body["stream"] as? Bool == true, "no server storage; streaming")
        for unsupported in ["max_output_tokens", "temperature", "previous_response_id", "background"] { check(body[unsupported] == nil, "omit unsupported " + unsupported) }
        rejects("empty question") { _ = try ResponseRequest.data(model: "test", input: AIInput(text: "", image: nil, imageType: nil)) }
        rejects("oversized question") { _ = try ResponseRequest.data(model: "test", input: AIInput(text: String(repeating: "a", count: 32001), image: nil, imageType: nil)) }
        try await responseChecks()
        print("PASS: \(passed) synthetic core checks; URLSession fixture checks passed. Foundation lines blank separators: \(legacyBlanks). No real account, clipboard, external network or device used.")
    }
    static var legacyBlanks = 0
    @MainActor static func responseChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func read(_ path: String) async throws -> String {
            let (bytes, response) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/" + path)!)
            return try await ResponseReader.read(bytes, response: response)
        }
        let (legacy, _) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/good")!)
        for try await line in legacy.lines { if line.isEmpty { legacyBlanks += 1 } }
        let normal = try await read("good")
        check(normal == "2", "production URLSession bytes LF framing")
        for path in ["crlf", "cr", "multiline", "bom", "unicode", "headerless", "octets", "plain-sse", "unknown-mime"] {
            let answer = try await read(path)
            check(answer == (path == "unicode" ? "정답 2" : "2"), "byte chunk fixture " + path)
        }
        // This fixture deliberately never signals socket EOF. A missing early
        // return would hang; the bounded timeout fails the check instead.
        let open = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/open")!)
                return try await ResponseReader.read(bytes, response: response)
            }
            group.addTask { try await Task.sleep(nanoseconds: 10_000_000_000); throw SafeFailure.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        check(open == "2", "completed response returns without EOF")
        let headerlessOpen = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/headerless-open")!)
                return try await ResponseReader.read(bytes, response: response)
            }
            group.addTask { try await Task.sleep(nanoseconds: 10_000_000_000); throw SafeFailure.timeout }
            defer { group.cancelAll() }; return try await group.next()!
        }
        check(headerlessOpen == "2", "headerless completed response returns without EOF")
        for (path, reason) in [("truncated", ResponseIssue.Reason.missingCompletion), ("malformed", .malformed),
                              ("failed", .failed), ("incomplete", .incomplete), ("json", .contentType), ("denied", .http)] {
            do { _ = try await read(path); fatalError("CHECK FAILED (accepted): " + path) }
            catch let issue as ResponseIssue {
                check(issue.reason == reason, "specific response failure " + path)
                if path == "failed" || path == "denied" {
                    check(issue.code == "subscription_sharing_user_not_eligible", "sanitized server code " + path)
                }
            }
        }
        for (path, shape, count) in [("html", "HTML", 52), ("empty-body", "empty", 0), ("gzip", "gzip", 4), ("plain-error", "other-text", 24)] {
            let (bytes, response) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/" + path)!)
            var progress = ResponseReader.Progress()
            do {
                _ = try await ResponseReader.read(bytes, response: response) { progress = $0 }
                fatalError("CHECK FAILED (accepted non-SSE body): " + path)
            } catch let issue as ResponseIssue {
                check(issue.reason == .contentType && issue.bodyShape == shape, "non-SSE classification " + path)
                check(progress.bytes == count && progress.bodyShape == shape, "non-SSE actual byte counter " + path)
            }
        }
        let (deniedBytes, deniedResponse) = try await session.bytes(from: URL(string: "https://calculator-fixture.invalid/denied-sse")!)
        do { _ = try await ResponseReader.read(deniedBytes, response: deniedResponse); fatalError("CHECK FAILED: non-2xx SSE accepted") }
        catch let issue as ResponseIssue { check(issue.reason == .http, "non-2xx cannot succeed via SSE sniffing") }
        var diagnostic = QuestionDiagnostic(); diagnostic.begin()
        diagnostic.fail(ResponseIssue(reason: .missingCompletion))
        let saved = diagnostic.failure
        check(saved != nil && diagnostic.terminal, "question error retained independently of model status")
        check(DiagnosticMetadata.identifier("Bearer secret") == nil, "diagnostic rejects bearer")
        check(DiagnosticMetadata.identifier("sk-synthetic-not-a-real-key") == nil, "diagnostic rejects secret prefix")
        check(DiagnosticMetadata.identifier("eyJsynthetic") == nil, "diagnostic rejects JWT prefix")
        check(DiagnosticMetadata.identifier(String(repeating: "x", count: 129)) == nil, "bounded metadata")
        check(DiagnosticMetadata.requestID("req_synthetic_123") == "req_synthetic_123", "request ID accepted")
        check(DiagnosticMetadata.requestID("private input") == nil, "arbitrary request ID excluded")
        check(DiagnosticMetadata.mediaType("text/event-stream; charset=utf-8") == "text/event-stream", "SSE content type parameters")
        check(DiagnosticMetadata.mediaType("private input") == "기타 MIME", "arbitrary content type excluded")
        check(DiagnosticMetadata.mediaType(nil) == "없음", "missing header distinguished")
        check(DiagnosticMetadata.mediaType("application/octet-stream") == "application/octet-stream", "binary header distinguished")
        check(DiagnosticMetadata.bodyShape(Data("data".utf8)) == nil, "fragmented SSE prefix waits")
        check(DiagnosticMetadata.bodyShape(Data("data:".utf8)) == "SSE", "complete SSE prefix recognized")
        let safe = ResponseIssue.server(["error": ["code": "synthetic_failure", "message": "PRIVATE SYNTHETIC QUESTION"]], reason: .failed)
        diagnostic.fail(safe)
        check(diagnostic.failure?.contains("synthetic_failure") == true && diagnostic.failure?.contains("PRIVATE") == false, "raw server messages excluded")
    }
    static func jwtChecks() throws {
        let privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let external = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        // Parse the two INTEGERs of the generated PKCS#1 key for a synthetic JWK.
        var offset = 0
        func readLength() -> Int {
            let first = Int(external[offset]); offset += 1
            if first < 128 { return first }
            var result = 0; for _ in 0..<(first & 127) { result = result * 256 + Int(external[offset]); offset += 1 }; return result
        }
        offset += 1; _ = readLength()
        offset += 1; let nLength = readLength(); let n = external.subdata(in: offset..<(offset + nLength)); offset += nLength
        offset += 1; let eLength = readLength(); let e = external.subdata(in: offset..<(offset + eLength))
        let jwk = JWKSet(keys: [.init(kty: "RSA", kid: "synthetic", n: OAuthContract.base64url(n), e: OAuthContract.base64url(e), alg: "RS256", use: "sig")])
        let now = Date(), aud = "oaiapp_synthetic", nonce = "synthetic-nonce"
        let claims: [String: Any] = ["iss": OAuthContract.issuer, "sub": "synthetic-subject", "aud": aud, "iat": now.timeIntervalSince1970, "exp": now.timeIntervalSince1970 + 3600, "nonce": nonce]
        func signed(_ payload: [String: Any], algorithm: String = "RS256") throws -> String {
            let header = OAuthContract.base64url(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "synthetic"]))
            let body = OAuthContract.base64url(try JSONSerialization.data(withJSONObject: payload))
            let message = Data((header + "." + body).utf8)
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
            return header + "." + body + "." + OAuthContract.base64url(signature)
        }
        let token = try signed(claims)
        check(try IDTokenVerifier.verify(token, keys: jwk, audience: aud, nonce: nonce).subject == "synthetic-subject", "RS256 valid signature")
        rejects("wrong audience") { _ = try IDTokenVerifier.verify(token, keys: jwk, audience: "other", nonce: nonce) }
        rejects("wrong nonce") { _ = try IDTokenVerifier.verify(token, keys: jwk, audience: aud, nonce: "other") }
        rejects("wrong refresh subject") { _ = try IDTokenVerifier.verify(token, keys: jwk, audience: aud, nonce: nil, subject: "other") }
        rejects("expired") { _ = try IDTokenVerifier.verify(token, keys: jwk, audience: aud, nonce: nonce, now: now.addingTimeInterval(7200)) }
        var evil = claims; evil["iss"] = "https://example.invalid"
        rejects("wrong issuer") { _ = try IDTokenVerifier.verify(signed(evil), keys: jwk, audience: aud, nonce: nonce) }
        rejects("algorithm confusion") { _ = try IDTokenVerifier.verify(signed(claims, algorithm: "HS256"), keys: jwk, audience: aud, nonce: nonce) }
        let parts = token.split(separator: ".").map(String.init)
        rejects("modified payload") { _ = try IDTokenVerifier.verify(parts[0] + "." + OAuthContract.base64url(Data("{}".utf8)) + "." + parts[2], keys: jwk, audience: aud, nonce: nonce) }
    }
}

// Only this ephemeral test session intercepts the reserved .invalid host.
// No request can leave this process and no real credentials are ever used.
final class ResponseFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "calculator-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"2\"}]}]}}\n\n"
        var body = "event: response.created\ndata: {\"type\":\"response.created\"}\n\n: heartbeat\n\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"2\"}\n\n" + completed
        var status = 200
        var type: String? = "text/event-stream; charset=utf-8"
        switch path {
        case "crlf": body = body.replacingOccurrences(of: "\n", with: "\r\n")
        case "cr": body = body.replacingOccurrences(of: "\n", with: "\r")
        case "bom": body = "\u{FEFF}" + body
        case "unicode": body = body.replacingOccurrences(of: "\"text\":\"2\"", with: "\"text\":\"정답 2\"")
        case "multiline": body = completed.replacingOccurrences(of: "\"response\":", with: "\n data: \"response\":").replacingOccurrences(of: "\n data:", with: "\ndata:")
        case "truncated": body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"2\"}\n\n"
        case "malformed": body = "data: not-json\n\n"
        case "failed": body = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_user_not_eligible\",\"message\":\"synthetic private text\"}}}\n\n"
        case "incomplete": body = "data: {\"type\":\"response.incomplete\"}\n\n"
        case "json": type = "application/json"; body = "{\"detail\":\"synthetic private text\"}"
        case "denied": status = 403; type = "application/json"; body = "{\"error\":{\"code\":\"subscription_sharing_user_not_eligible\"}}"
        case "denied-sse": status = 403
        case "headerless", "headerless-open": type = nil
        case "octets": type = "application/octet-stream"
        case "plain-sse": type = "text/plain"
        case "unknown-mime": type = "application/x-synthetic-stream"
        case "html": type = nil; body = "<!doctype html><html><body>unavailable</body></html>"
        case "empty-body": type = nil; body = ""
        case "plain-error": type = nil; body = "synthetic upstream error"
        case "gzip": type = "application/octet-stream"
        default: break
        }
        var headers = ["x-request-id": "req_synthetic_test"]
        if let type { headers["Content-Type"] = type }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = path == "gzip" ? Data([31, 139, 8, 0]) : Data(body.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 7) { client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(bytes.count, offset + 7))) }
        if path != "open", path != "headerless-open" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

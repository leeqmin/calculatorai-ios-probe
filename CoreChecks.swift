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
    static func main() throws {
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
        print("PASS: \(passed) synthetic core checks. No account, clipboard, network or device used.")
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

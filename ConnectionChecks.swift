#if DEBUG
import Foundation

// This file is entirely absent from Release. Every credential/body is synthetic.
// The private session intercepts ALL URLs; unexpected routes fail closed locally.
final class ConnectionFixture: URLProtocol {
    struct Reply {
        var status = 200
        var body: String
        var delay: Double = 0
        var type = "application/json"
    }
    struct Counts {
        var refresh = 0, models = 0, responses = 0, unexpected = 0
        var refreshedBearer = false, rotatedRefresh = false
    }
    private static let lock = NSLock()
    private static var replies: [String: [Reply]] = [:]
    private static var tally = Counts()
    private let stopLock = NSLock()
    private var stopped = false
    static func configure(refresh: [Reply] = [], models: [Reply] = [], responses: [Reply] = []) {
        lock.lock(); defer { lock.unlock() }
        replies = ["/api/accounts/oauth/token": refresh, "/v1/models": models, "/v1/responses": responses]; tally = Counts()
    }
    static var counts: Counts { lock.lock(); defer { lock.unlock() }; return tally }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        var plan = Self.replies[path] ?? []
        let reply = plan.isEmpty ? nil : plan.removeFirst()
        Self.replies[path] = plan
        switch path {
        case "/api/accounts/oauth/token":
            Self.tally.refresh += 1
            let body = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size)) }
                return data
            } ?? Data()
            if String(data: body, encoding: .utf8)?.contains("refresh_token=synthetic-rotated-refresh") == true { Self.tally.rotatedRefresh = true }
        case "/v1/models": Self.tally.models += 1
        case "/v1/responses": Self.tally.responses += 1
        default: Self.tally.unexpected += 1
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-fresh-access" { Self.tally.refreshedBearer = true }
        Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stopLock.lock(); let active = !stopped; stopLock.unlock(); guard active else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.type, "x-request-id": "req_synthetic_connection"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopLock.lock(); stopped = true; stopLock.unlock() }
}

@MainActor enum ConnectionChecks {
    final class MemoryStore {
        var values: [String: Data] = [:]
        var boundary: ConnectionStorage { ConnectionStorage(read: { self.values[$0] }, write: { self.values[$1] = $0 }) }
    }
    static let alpha = "synthetic-alpha", beta = "synthetic-beta"
    static var passed = 0, errors: [String] = []
    static func check(_ value: Bool, _ label: String) { if value { passed += 1 } else { errors.append(label) } }
    static func record(_ subject: String = "synthetic-a", expired: Bool = false, model: String? = alpha) -> AccountRecord {
        AccountRecord(subject: subject, clientID: "oaiapp_synthetic", label: "Synthetic account",
            accessToken: "synthetic-old-access", refreshToken: "synthetic-old-refresh", idToken: nil,
            expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600), scopes: [OAuthContract.planScope], model: model, usageAcknowledged: true)
    }
    static func make(_ records: [AccountRecord], now: @escaping () -> Date = Date.init) throws -> (ChatGPTConnection, MemoryStore) {
        let memory = MemoryStore()
        memory.values = ["host": Data("urn:uuid:synthetic-connection".utf8), "accounts": try JSONEncoder().encode(records),
                         "selected-account": Data(records[0].id.utf8)]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConnectionFixture.self]
        let connection = ChatGPTConnection(storage: memory.boundary, transport: OfficialTransport(configuration: config),
            exchangeFactory: { ResponseExchange(configuration: config) }, now: now)
        return (connection, memory)
    }
    static func catalog(_ slugs: [String] = [alpha, beta], delay: Double = 0) -> ConnectionFixture.Reply {
        let body = try! JSONSerialization.data(withJSONObject: ["models": slugs.map { ["slug": $0, "display_name": $0, "visibility": "list"] }])
        return .init(body: String(decoding: body, as: UTF8.self), delay: delay)
    }
    static func refresh(delay: Double = 0) -> ConnectionFixture.Reply {
        .init(body: "{\"access_token\":\"synthetic-fresh-access\",\"refresh_token\":\"synthetic-rotated-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}", delay: delay)
    }
    static func completed() -> ConnectionFixture.Reply {
        .init(body: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"2\"}]}]}}\n\n", type: "text/event-stream")
    }
    static func send(_ connection: ChatGPTConnection) async -> Result<String, Error> {
        let id = connection.beginQuestion()
        do {
            let answer = try await connection.answer(AIInput(text: "synthetic 1+1", image: nil, imageType: nil), diagnosticID: id)
            connection.finishQuestion(id); return .success(answer)
        } catch { connection.finishQuestion(id, error: error); return .failure(error) }
    }
    static func waitUntil(_ condition: () -> Bool) async {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    static func run() async {
        passed = 0; errors = []
        do { try await scenarios() } catch { errors.append("unexpected synthetic scenario failure") }
        let report = errors.isEmpty ? "PASS: \(passed) connection recovery checks; memory storage, private URLProtocol, synthetic accounts only. No external network/Keychain/clipboard." : "FAIL: " + errors.joined(separator: ", ")
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.write(to: folder.appendingPathComponent("connection-checks.txt"), atomically: true, encoding: .utf8)
        }
    }
    static func scenarios() async throws {
        ConnectionFixture.configure(models: [catalog()], responses: [completed()])
        let (normal, _) = try make([record()])
        let answer = await send(normal)
        check((try? answer.get()) == "2" && normal.question.stage == "완료", "cached account end-to-end completion")
        check(ConnectionFixture.counts.responses == 1 && ConnectionFixture.counts.refresh == 0, "one inference no needless refresh")

        ConnectionFixture.configure(models: [catalog()])
        let (newAccount, _) = try make([record(model: nil)])
        _ = await send(newAccount)
        check(newAccount.selectedModel == nil && newAccount.usableModel == nil && ConnectionFixture.counts.responses == 0, "new account requires explicit model selection")

        var clock = Date()
        ConnectionFixture.configure(refresh: [refresh(delay: 0.15), refresh()], models: [catalog(), catalog(), catalog()], responses: [completed()])
        let (rotating, _) = try make([record()], now: { clock })
        await rotating.loadModels(); clock = clock.addingTimeInterval(7200)
        let loading = Task { await rotating.loadModels() }
        await waitUntil { ConnectionFixture.counts.refresh == 1 }
        rotating.chooseModel(beta)
        let duplicate = Task { await rotating.loadModels() }
        await loading.value; await duplicate.value
        check(ConnectionFixture.counts.refresh == 1 && ConnectionFixture.counts.models == 2, "serialized refresh and coalesced catalog loads")
        check(rotating.selected?.refreshToken == "synthetic-rotated-refresh" && rotating.selectedModel == beta, "refresh rotation preserves current model choice")
        check(ConnectionFixture.counts.refreshedBearer, "new bearer used for catalog")
        clock = clock.addingTimeInterval(7200); await rotating.loadModels()
        check(ConnectionFixture.counts.rotatedRefresh, "next renewal uses rotated refresh token")
        check((try? await send(rotating).get()) == "2", "inference after renewal")

        for (status, code, expected) in [(400, "invalid_grant", RecoveryAction.signIn), (401, "invalid_client", .clientConfiguration),
                                        (503, "temporarily_unavailable", .wait), (401, "unknown_auth_error", .permission)] {
            ConnectionFixture.configure(refresh: [.init(status: status, body: "{\"error\":\"\(code)\",\"error_description\":\"PRIVATE SYNTHETIC TOKEN\"}")])
            let (connection, memory) = try make([record(expired: true)])
            _ = await send(connection)
            check(connection.lastConnectionIssue?.phase == .refresh && connection.lastConnectionIssue?.action == expected, "refresh recovery classification " + code)
            check(connection.question.failure?.contains(code) == true && connection.question.failure?.contains("PRIVATE") == false, "refresh metadata retained without raw description " + code)
            let saved = try JSONDecoder().decode([AccountRecord].self, from: memory.values["accounts"]!)[0]
            if expected == .signIn {
                check(saved.accessToken.isEmpty && saved.refreshToken == nil && saved.clientID == "oaiapp_synthetic", "only confirmed unusable tokens cleared")
                _ = await send(connection)
                check(ConnectionFixture.counts.refresh == 1, "unusable refresh never retried")
            } else { check(saved.accessToken == "synthetic-old-access" && saved.refreshToken == "synthetic-old-refresh", "temporary/client/unknown failure preserves credentials " + code) }
            check(ConnectionFixture.counts.responses == 0, "no inference after refresh failure " + code)
        }

        ConnectionFixture.configure(models: [.init(status: 503, body: "{\"detail\":\"PRIVATE SYNTHETIC QUESTION\"}"), catalog()])
        let (admission, _) = try make([record()])
        _ = await send(admission)
        let diagnosticID = admission.question.id, savedFailure = admission.question.failure
        check(admission.lastConnectionIssue?.httpStatus == 503 && admission.lastConnectionIssue?.bodyShape == "detail", "catalog status and detail shape preserved")
        check(admission.question.failure?.contains("PRIVATE") == false && admission.question.failure?.contains("모델 목록 조회") == true, "catalog failure not replaced by model-required")
        await admission.loadModels()
        check(admission.question.id == diagnosticID && admission.question.failure == savedFailure && admission.lastConnectionIssue?.httpStatus == 503, "successful refresh cannot overwrite original diagnostics")

        ConnectionFixture.configure(models: [catalog(), catalog([beta])], responses: [.init(status: 404, body: "{\"error\":{\"code\":\"model_not_found\",\"param\":\"model\",\"message\":\"PRIVATE SYNTHETIC MODEL\"}}"), completed()])
        let (changed, _) = try make([record()])
        _ = await send(changed)
        check(ConnectionFixture.counts.models == 2 && ConnectionFixture.counts.responses == 1, "definitive model error refreshes catalog once without resending")
        check(changed.selectedModel == alpha && changed.usableModel == nil, "missing model is not silently replaced")
        check(changed.question.failure?.contains("model_not_found") == true && changed.question.httpStatus == 404, "original model rejection remains visible")
        _ = await send(changed)
        check(ConnectionFixture.counts.responses == 1, "unselected replacement cannot send")
        changed.chooseModel(beta)
        check((try? await send(changed).get()) == "2" && ConnectionFixture.counts.responses == 2, "explicit new selection and explicit send recover")

        for (code, parameter, status, expected) in [("subscription_sharing_usage_limit_exceeded", "", 429, RecoveryAction.usage),
            ("subscription_sharing_unsupported_capability", "input", 400, .request), ("subscription_sharing_user_not_eligible", "", 403, .permission)] {
            ConnectionFixture.configure(models: [catalog()], responses: [.init(status: status, body: "{\"error\":{\"code\":\"\(code)\",\"param\":\"\(parameter)\"}}")])
            let (connection, _) = try make([record()]); _ = await send(connection)
            check(connection.lastConnectionIssue?.action == expected && ConnectionFixture.counts.models == 1 && ConnectionFixture.counts.responses == 1, "no model fallback or inference retry for " + code)
        }

        ConnectionFixture.configure(models: [catalog(), catalog([beta])], responses: [.init(body: "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_unsupported_capability\",\"param\":\"model\"}}}\n\n", type: "text/event-stream")])
        let (streamFailure, _) = try make([record()]); _ = await send(streamFailure)
        check(streamFailure.question.httpStatus == 200 && streamFailure.lastConnectionIssue?.action == .model && ConnectionFixture.counts.responses == 1 && ConnectionFixture.counts.models == 2, "stream failure is not HTTP success and triggers only model GET")

        ConnectionFixture.configure(models: [.init(body: "{\"unexpected\":\"PRIVATE SYNTHETIC SCHEMA\"}")])
        let (schema, _) = try make([record()]); _ = await send(schema)
        check(schema.lastConnectionIssue?.httpStatus == 200 && schema.lastConnectionIssue?.action == .inspect && ConnectionFixture.counts.responses == 0, "changed model schema gets bounded diagnosis not fake success")

        ConnectionFixture.configure(models: [catalog(delay: 0.15)])
        let (cancelled, _) = try make([record()])
        let cancelledRequest = Task { await send(cancelled) }
        await waitUntil { ConnectionFixture.counts.models == 1 }; cancelledRequest.cancel()
        _ = await cancelledRequest.value
        check(ConnectionFixture.counts.responses == 0 && cancelled.question.stage == "취소됨", "cancel before catalog completion never sends inference")

        ConnectionFixture.configure(refresh: [refresh(delay: 0.15)], models: [catalog([beta])])
        let (switching, _) = try make([record(expired: true), record("synthetic-b", model: beta)])
        let old = Task { await send(switching) }
        await waitUntil { ConnectionFixture.counts.refresh == 1 }
        switching.selectAccount(record("synthetic-b", model: beta).id)
        _ = await old.value
        await waitUntil { switching.usableModel == beta }
        check(switching.selected?.subject == "synthetic-b" && switching.usableModel == beta && ConnectionFixture.counts.responses == 0, "account switch rejects old refresh and old question")
        check(ConnectionFixture.counts.unexpected == 0, "fixture never permits external fallback")
    }
}
#endif

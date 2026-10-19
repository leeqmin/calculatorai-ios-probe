import Foundation
import SwiftUI
import Security
import Network
import UIKit

enum SecureStore {
    private static let service = "org.local.scientificcalculator.chatgpt"
    static func read(_ key: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SafeFailure.keychain }; return result as? Data
    }
    static func write(_ data: Data, key: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw SafeFailure.keychain }
        } else if status != errSecSuccess { throw SafeFailure.keychain }
    }
}

// No bearer credentials can follow a redirect to another host. System TLS validation is unchanged.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class OfficialTransport: @unchecked Sendable {
    static let shared = OfficialTransport()
    let session: URLSession
    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 240
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    func data(_ request: URLRequest, maximum: Int = 2_000_000) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)
        var result = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); result.append(byte)
            if result.count > maximum { throw SafeFailure.tooLarge }
        }
        return result
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SafeFailure.network }
        if http.statusCode == 401 { throw SafeFailure.loginRequired }
        if http.statusCode == 429 { throw SafeFailure.rateLimit }
        guard (200..<300).contains(http.statusCode) else { throw SafeFailure.requestFailed }
    }
}

@MainActor final class LoopbackServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var expired: Task<Void, Never>?
    private var waiting: CheckedContinuation<AuthorizationCode, Error>?
    private var transaction: LoginTransaction?
    private var consumed = false
    var onReady: ((UInt16) -> Void)?

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.listener === server else { return }
                switch state {
                case .ready: if let port = server.port { self.onReady?(port.rawValue) }
                case .failed: self.finish(.failure(SafeFailure.network))
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        server.start(queue: .main)
        expired = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }; self?.finish(.failure(SafeFailure.timeout))
        }
    }
    func wait(transaction: LoginTransaction) async throws -> AuthorizationCode {
        self.transaction = transaction
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: SafeFailure.cancelled) }
                else { waiting = continuation }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, !consumed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        Task { [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let connection, self?.connections.removeValue(forKey: id) != nil { connection.cancel() }
        }
        receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = accumulated; if let data { buffer.append(data) }
                guard buffer.count <= 8192, error == nil else { self.reject(connection, id: id); return }
                guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { self.reject(connection, id: id) } else { self.receive(connection, id: id, accumulated: buffer) }; return
                }
                guard !self.consumed, let port = self.listener?.port?.rawValue,
                      let transaction = self.transaction,
                      let target = LoopbackRequest.target(buffer, port: port) else { self.reject(connection, id: id); return }
                do {
                    let result = try AuthorizationCode.parse(target, transaction: transaction)
                    self.consumed = true
                    self.respond(connection, id: id, status: "200 OK", body: "로그인 응답을 받았습니다. 공학용 계산기 앱으로 돌아가세요.") {
                        self.finish(.success(result))
                    }
                } catch SafeFailure.denied {
                    self.consumed = true
                    self.respond(connection, id: id, status: "200 OK", body: "로그인이 취소됐습니다. 계산기로 돌아가세요.") { self.finish(.failure(SafeFailure.denied)) }
                } catch { self.reject(connection, id: id) }
            }
        }
    }
    private func reject(_ connection: NWConnection, id: UUID) {
        respond(connection, id: id, status: "400 Bad Request", body: "잘못된 요청입니다.", done: {})
    }
    private func respond(_ connection: NWConnection, id: UUID, status: String, body: String, done: @escaping () -> Void) {
        let html = Data(("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>공학용 계산기</title><p>" + body + "</p>").utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + html, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in connection.cancel(); self?.connections.removeValue(forKey: id); done() }
        })
    }
    private func finish(_ result: Result<AuthorizationCode, Error>) {
        let continuation = waiting; waiting = nil
        listener?.cancel(); listener = nil; expired?.cancel(); expired = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        transaction = nil; onReady = nil
        continuation?.resume(with: result)
    }
    func cancel() { finish(.failure(SafeFailure.cancelled)) }
}

@MainActor final class ChatGPTConnection: ObservableObject {
    @Published private(set) var accounts: [AccountRecord] = []
    @Published var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "selected-account") } }
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var status = "기기에서 실제 로그인·AI 요청 확인이 필요합니다."
    @Published private(set) var busy = false
    @Published var showUsageNotice = false
    private var host = ""
    private var epoch = UUID()
    private var loginTask: Task<Void, Never>?
    private var refreshTask: Task<AccountRecord, Error>?
    private var server: LoopbackServer?
    private var background = UIBackgroundTaskIdentifier.invalid
    var selected: AccountRecord? { accounts.first(where: { $0.id == selectedID }) }
    var selectedModel: String? { selected?.model }

    init() {
        do {
            if let data = try SecureStore.read("host"), let saved = String(data: data, encoding: .utf8) { host = saved }
            else { host = "urn:uuid:" + UUID().uuidString.lowercased(); try SecureStore.write(Data(host.utf8), key: "host") }
            if let saved = try SecureStore.read("accounts") { accounts = try JSONDecoder().decode([AccountRecord].self, from: saved) }
            selectedID = UserDefaults.standard.string(forKey: "selected-account")
            if selected == nil { selectedID = accounts.first?.id }
        } catch { status = SafeFailure.keychain.message }
    }
    private func save(_ updated: [AccountRecord]) throws {
        try SecureStore.write(JSONEncoder().encode(updated), key: "accounts"); accounts = updated
    }
    func acknowledgeUsage() {
        guard let current = selected else { return }
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == current.id }) { updated[index].usageAcknowledged = true }
        do { try save(updated) } catch { status = SafeFailure.keychain.message }
        showUsageNotice = false
    }
    func chooseModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }), let current = selected else { return }
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == current.id }) { updated[index].model = slug }
        do { try save(updated) } catch { status = SafeFailure.keychain.message }
    }
    func selectAccount(_ id: String) {
        cancelLogin(); refreshTask?.cancel(); refreshTask = nil; epoch = UUID()
        selectedID = id; models = []; Task { await loadModels() }
    }
    func disconnect() {
        cancelLogin(); refreshTask?.cancel(); refreshTask = nil; epoch = UUID()
        let remaining = accounts.filter { $0.id != selectedID }
        do { try save(remaining); selectedID = remaining.first?.id; models = []; status = "이 기기에서 연결을 해제했습니다. 서버 권한 취소는 ChatGPT 설정에서 직접 할 수 있습니다." }
        catch { status = SafeFailure.keychain.message }
    }
    func cancelLogin() {
        loginTask?.cancel(); loginTask = nil; server?.cancel(); server = nil; busy = false
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }
    func login(asNewAccount: Bool = false) {
        guard !busy, !host.isEmpty else { return }
        busy = true; status = "Safari에서 로그인한 뒤 계산기 앱으로 돌아오세요."
        let generation = UUID(); epoch = generation
        let existing = asNewAccount ? nil : selected
        let loopback = LoopbackServer(); server = loopback
        background = UIApplication.shared.beginBackgroundTask(withName: "OfficialLogin") { [weak self] in
            Task { @MainActor in self?.status = "로그인 중 계산기로 돌아온 후 다시 시도하세요. iOS가 대기를 종료했습니다."; self?.cancelLogin() }
        }
        loopback.onReady = { [weak self, weak loopback] port in
            guard let self, let loopback, self.epoch == generation else { return }
            self.loginTask = Task {
                defer { if self.epoch == generation { self.cancelLogin() } }
                do {
                    let transaction = try LoginTransaction(port: port, existingClient: existing?.clientID)
                    let url = try OAuthContract.authorization(transaction: transaction, host: self.host)
                    // Install the continuation before handing off to the system browser.
                    let codeTask = Task { try await loopback.wait(transaction: transaction) }
                    await Task.yield()
                    guard await UIApplication.shared.open(url) else { codeTask.cancel(); throw SafeFailure.network }
                    let code = try await codeTask.value
                    try Task.checkCancellation()
                    var request = URLRequest(url: OAuthContract.tokenURL)
                    request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = OAuthContract.form(["grant_type": "authorization_code", "client_id": code.clientID,
                        "code": code.code, "code_verifier": transaction.verifier, "redirect_uri": transaction.redirect, "resource": OAuthContract.resource])
                    let reply = try JSONDecoder().decode(TokenReply.self, from: await OfficialTransport.shared.data(request))
                    guard let idToken = reply.id_token else { throw SafeFailure.invalidToken }
                    let identity = try IDTokenVerifier.verify(idToken, keys: await self.keys(), audience: code.clientID, nonce: transaction.nonce, subject: existing?.subject)
                    let scopes = (reply.scope ?? "").split(separator: " ").map(String.init)
                    guard scopes.contains(OAuthContract.planScope) else { throw SafeFailure.missingScope }
                    guard !reply.access_token.isEmpty, reply.token_type?.lowercased() == "bearer", let expiry = reply.expires_in, expiry > 0, expiry < 31_536_000 else { throw SafeFailure.invalidToken }
                    guard self.epoch == generation, !Task.isCancelled else { throw SafeFailure.cancelled }
                    let record = AccountRecord(subject: identity.subject, clientID: code.clientID, label: identity.label,
                        accessToken: reply.access_token, refreshToken: reply.refresh_token, expiresAt: Date().addingTimeInterval(expiry), scopes: scopes,
                        model: existing?.model, usageAcknowledged: existing?.usageAcknowledged ?? false)
                    var updated = self.accounts.filter { $0.id != record.id }; updated.append(record)
                    try self.save(updated); self.selectedID = record.id; self.models = []
                    self.showUsageNotice = !record.usageAcknowledged
                    self.status = "로그인 검증 완료. ChatGPT 플랜의 사용량과 제한을 공유합니다."
                    await self.loadModels()
                } catch { if self.epoch == generation { self.status = Self.safe(error).message } }
            }
        }
        do { try loopback.start() } catch { status = SafeFailure.network.message; cancelLogin() }
    }
    private func keys() async throws -> JWKSet {
        try JSONDecoder().decode(JWKSet.self, from: await OfficialTransport.shared.data(URLRequest(url: OAuthContract.jwksURL)))
    }
    private func token() async throws -> String {
        guard let record = selected else { throw SafeFailure.loginRequired }
        guard record.scopes.contains(OAuthContract.planScope) else { throw SafeFailure.missingScope }
        if record.expiresAt.timeIntervalSinceNow > 60 { return record.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refresh = record.refreshToken else { throw SafeFailure.loginRequired }
        let generation = epoch
        let task = Task { @MainActor () throws -> AccountRecord in
            var request = URLRequest(url: OAuthContract.tokenURL); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthContract.form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": record.clientID, "resource": OAuthContract.resource])
            let reply = try JSONDecoder().decode(TokenReply.self, from: await OfficialTransport.shared.data(request))
            if let idToken = reply.id_token { _ = try IDTokenVerifier.verify(idToken, keys: await self.keys(), audience: record.clientID, nonce: nil, subject: record.subject) }
            let scopes = reply.scope.map { $0.split(separator: " ").map(String.init) } ?? record.scopes
            guard scopes.contains(OAuthContract.planScope), !reply.access_token.isEmpty,
                  reply.token_type?.lowercased() == "bearer", let expiry = reply.expires_in, expiry > 0, expiry < 31_536_000 else { throw SafeFailure.invalidToken }
            try Task.checkCancellation(); guard self.epoch == generation, self.selectedID == record.id else { throw SafeFailure.cancelled }
            // Merge into the current record, preserving model and acknowledgement changes during refresh.
            guard let index = self.accounts.firstIndex(where: { $0.id == record.id }) else { throw SafeFailure.cancelled }
            var updated = self.accounts; updated[index].accessToken = reply.access_token
            updated[index].refreshToken = reply.refresh_token ?? record.refreshToken
            updated[index].expiresAt = Date().addingTimeInterval(expiry); updated[index].scopes = scopes
            try self.save(updated); return updated[index]
        }
        refreshTask = task
        defer { if epoch == generation { refreshTask = nil } }
        return try await task.value.accessToken
    }
    func loadModels() async {
        let generation = epoch, account = selectedID
        do {
            let token = try await token()
            var request = URLRequest(url: URL(string: OAuthContract.resource + "/models")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let catalog = try JSONDecoder().decode(ModelCatalog.self, from: await OfficialTransport.shared.data(request))
            guard epoch == generation, account == selectedID else { return }
            models = catalog.models.filter { $0.visibility == "list" && !$0.slug.isEmpty }
            guard !models.isEmpty else { throw SafeFailure.models }
            if !models.contains(where: { $0.slug == selectedModel }) { chooseModel(models[0].slug) }
            status = "사용 가능한 모델 \(models.count)개. 실제 질문 전송은 별도 확인이 필요합니다."
        } catch { if generation == epoch { status = Self.safe(error).message } }
    }
    func answer(_ input: AIInput) async throws -> String {
        guard let selected, selected.usageAcknowledged else { showUsageNotice = true; throw SafeFailure.loginRequired }
        if models.isEmpty { await loadModels() }
        guard let slug = selectedModel, models.contains(where: { $0.slug == slug }) else { throw SafeFailure.modelRequired }
        let credential = try await token(), generation = epoch, account = selectedID
        var request = URLRequest(url: URL(string: OAuthContract.resource + "/responses")!)
        request.httpMethod = "POST"; request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try ResponseRequest.data(model: slug, input: input)
        let (bytes, response) = try await OfficialTransport.shared.session.bytes(for: request)
        try OfficialTransport.validate(response)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw SafeFailure.incomplete }
        var stream = ResponseStream(), total = 0
        for try await line in bytes.lines {
            try Task.checkCancellation(); guard epoch == generation, selectedID == account else { throw SafeFailure.cancelled }
            total += line.utf8.count; guard total < 8_000_000 else { throw SafeFailure.tooLarge }
            try stream.receive(line)
        }
        return try stream.finish()
    }
    func recordFailure(_ error: Error) { status = Self.safe(error).message }
    static func safe(_ error: Error) -> SafeFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? SafeFailure { return failure }
        if let network = error as? URLError, network.code == .timedOut { return .timeout }
        return .network
    }
}

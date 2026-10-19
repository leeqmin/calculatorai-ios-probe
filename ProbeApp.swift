import SwiftUI
import SafariServices
import Network

@main
struct CalculatorProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct BrowserPage: Identifiable {
    let id = UUID()
    let url: URL
}

struct ProbeBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct ProbeView: View {
    @StateObject private var probe = LoopbackProbe()
    var body: some View {
        NavigationStack {
            Form {
                Section("아이폰 네이티브 연결 시험") {
                    Text("실제 ChatGPT 로그인·AI 호출은 아직 구현하지 않았습니다.")
                    Text("앱 안에서 브라우저가 열리고, 모의 승인을 누르면 이 화면으로 돌아오는지 확인합니다.")
                    Button("앱 안에서 복귀 시험") { probe.start(external: false) }
                        .disabled(probe.running)
                    Button("외부 Safari 복귀 수신 시험") { probe.start(external: true) }
                        .disabled(probe.running)
                    Text("외부 Safari 시험은 수신 후 앱으로 직접 돌아오세요. 자동 복귀는 시험하지 않습니다.")
                        .font(.footnote)
                    if probe.running { Button("시험 취소", role: .cancel) { probe.cancel() } }
                }
                Section("시험 상태") {
                    Text(probe.status).accessibilityIdentifier("probeStatus")
                    Text("이 시험은 127.0.0.1만 사용합니다. 계정·API 키·사진을 입력하지 마세요.")
                        .font(.footnote)
                    Text("통과해도 OpenAI의 실제 로그인·구독 사용 권한·토큰 저장·AI 응답 성공을 의미하지 않습니다.")
                        .font(.footnote)
                }
            }
            .navigationTitle("계산기AI 연결 시험")
            .sheet(item: $probe.page, onDismiss: { if probe.running { probe.cancel() } }) {
                ProbeBrowser(url: $0.url)
            }
        }
    }
}

// No external service, OAuth token, private API, background mode, or credential storage.
final class LoopbackProbe: ObservableObject {
    @Published var status = "미시험"
    @Published var running = false
    @Published var page: BrowserPage?
    private var listener: NWListener?
    private var transaction: ProbeTransaction?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: DispatchWorkItem?
    private var generation = UUID()

    func start(external: Bool) {
        cancel()
        generation = UUID()
        let attempt = generation
        let parameters = NWParameters.tcp
        // Binding an explicit loopback address is essential: never listen on 0.0.0.0.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let server = try NWListener(using: parameters)
            listener = server
            transaction = ProbeTransaction()
            running = true
            status = "기기 내부 수신기 시작 중"
            server.newConnectionHandler = { [weak self] connection in
                guard let self = self, self.generation == attempt, self.running,
                      self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.connections.removeValue(forKey: id)?.cancel()
                }
                self.receive(connection, id: id, buffer: Data(), attempt: attempt)
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self = self, let server = server, self.generation == attempt else { return }
                switch state {
                case .ready:
                    guard let port = server.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/probe") else {
                        self.finish("실패: 수신 포트 없음"); return
                    }
                    self.status = "모의 승인 대기 중 (최대 120초)"
                    if external {
                        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                            DispatchQueue.main.async {
                                guard let self = self, self.generation == attempt else { return }
                                if !opened { self.finish("실패: Safari 열기 거부") }
                            }
                        }
                    } else { self.page = BrowserPage(url: url) }
                case .failed: self.finish("실패: 기기 내부 수신기를 시작할 수 없음")
                default: break
                }
            }
            server.start(queue: .main)
            let expiry = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == attempt else { return }
                self.finish("실패: 시간 초과 — 브라우저 또는 앱 백그라운드 제한 확인 필요")
            }
            timeout = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: expiry)
        } catch { finish("실패: 수신기 생성 불가") }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data, attempt: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self = self, self.generation == attempt, self.running,
                  self.connections[id] != nil else { connection.cancel(); return }
            var bytes = buffer
            if let data = data { bytes.append(data) }
            guard bytes.count <= 8192 else { self.respond(connection, id: id, status: "413 Payload Too Large", html: "Too large"); return }
            if let marker = bytes.range(of: Data("\r\n\r\n".utf8)) {
                guard marker.upperBound == bytes.endIndex,
                      let header = String(data: bytes, encoding: .utf8),
                      let port = self.listener?.port,
                      let request = try? ProbeRequest(header, port: port.rawValue) else {
                    self.respond(connection, id: id, status: "400 Bad Request", html: "Invalid request"); return
                }
                self.route(request, connection: connection, id: id)
            } else if complete || error != nil {
                self.connections.removeValue(forKey: id)?.cancel()
            } else { self.receive(connection, id: id, buffer: bytes, attempt: attempt) }
        }
    }

    private func route(_ request: ProbeRequest, connection: NWConnection, id: UUID) {
        if request.path == "/probe", request.query.isEmpty, let transaction = transaction {
            let html = """
            <!doctype html><html lang="ko"><meta name="viewport" content="width=device-width">
            <title>기기 내부 모의 승인</title><h1>실제 로그인이 아닙니다</h1>
            <p>60초 정도 기다린 뒤 눌러도 수신되는지 시험하세요. 계정 정보는 입력하지 않습니다.</p>
            <p><a href="/auth/callback?state=\(transaction.state)&amp;code=probe-only&amp;client_id=probe-client">모의 승인</a></p></html>
            """
            respond(connection, id: id, status: "200 OK", html: html)
        } else if request.path == "/auth/callback" {
            do {
                guard var current = transaction else { throw ProbeError.invalidRequest }
                try current.consume(request)
                transaction = current
                let attempt = generation
                respond(connection, id: id, status: "200 OK", html: "<h1>모의 수신 성공</h1><p>앱으로 돌아가세요.</p>") { [weak self] in
                    guard let self = self, self.generation == attempt else { return }
                    self.finish("모의 수신 성공 — 실제 ChatGPT 연결은 아직 미검증")
                }
            } catch { respond(connection, id: id, status: "400 Bad Request", html: "Invalid or expired callback") }
        } else { respond(connection, id: id, status: "404 Not Found", html: "Not found") }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: String, html: String, after: (() -> Void)? = nil) {
        let body = Data(html.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.connections.removeValue(forKey: id)?.cancel()
            after?()
        })
    }

    func cancel() { finish(running ? "취소됨" : status) }
    private func finish(_ text: String) {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        transaction = nil
        running = false
        page = nil
        status = text
    }
}

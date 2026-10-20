import SwiftUI
import UIKit
import WebKit

@MainActor final class CalculatorModel: ObservableObject {
    @Published var engine = ScientificEngine()
    @Published private(set) var ai = false
    @Published private(set) var pending = false
    @Published private(set) var pages: [String] = []
    @Published private(set) var page = 0
    @Published var draft = ""
    @Published var keyboard = false
    @Published var settings = false
    // Ordinary calculator launch never needs account storage or authentication setup.
    lazy var connection = ChatGPTConnection()
    private var sequence = HiddenSequence()
    private var snapshot: ScientificEngine?
    private var draftSnapshot: (text: String, selection: NSRange, pages: [String], page: Int)?
    private var draftSelection = NSRange(location: 0, length: 0)
    private var syncingField = false
    // Weak, view-owned reference: no new keyboard/clipboard/auth path.
    weak var inputField: UITextField?
    private var lastEquals: TimeInterval?
    private var equalsTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var generation = UUID()
    #if DEBUG
    var syntheticResponder: ((AIInput) async throws -> String)?
    #endif
    var answer: String { pages.isEmpty ? "0" : pages[min(page, pages.count - 1)] }

    func press(_ key: String) {
        if ai && !pending { commitField() }
        let now = ProcessInfo.processInfo.systemUptime
        let before = engine
        let beforeDraft = (text: draft, selection: draftSelection, pages: pages, page: page)
        let oldIndex = sequence.index
        if sequence.accept(key, now: now) {
            if let snapshot { engine = snapshot }
            if ai, let saved = draftSnapshot {
                draft = saved.text; draftSelection = saved.selection; pages = saved.pages; page = saved.page; syncField()
            }
            snapshot = nil; draftSnapshot = nil; keyboard = false; equalsTask?.cancel(); lastEquals = nil; settings = true; return
        }
        if sequence.index == 1, (oldIndex == 0 || key == "ln") { snapshot = before; draftSnapshot = beforeDraft }
        if sequence.index == 0 { snapshot = nil; draftSnapshot = nil }
        if key == "C" { clear(); return }
        if key == "=" {
            if let previous = lastEquals, now - previous <= 0.33 {
                equalsTask?.cancel(); equalsTask = nil; lastEquals = nil
                if !ai { ai = true; pages = []; page = 0; draft = ""; draftSelection = NSRange(location: 0, length: 0); syncField() }
                return
            }
            lastEquals = now; equalsTask?.cancel()
            if !ai {
                equalsTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 335_000_000)
                    guard !Task.isCancelled, let self, !self.ai else { return }
                    self.engine.press("="); self.lastEquals = nil
                }
            }
            return
        }
        if !ai {
            if lastEquals != nil { equalsTask?.cancel(); engine.press("="); lastEquals = nil }
            engine.press(key)
        } else if !pending {
            var editor = QuestionDraft(draft, selection: draftSelection)
            if editor.press(key) {
                draft = editor.text; draftSelection = editor.selection; pages = []; page = 0; syncField()
            }
        }
    }
    private func commitField() {
        guard let field = inputField, field.isFirstResponder else { return }
        field.unmarkText()
        fieldChanged(field)
    }
    func fieldChanged(_ field: UITextField) {
        guard ai, !pending, !syncingField else { return }
        let text = field.text ?? ""
        if draft != text { draft = text; pages = []; page = 0 }
        if let range = field.selectedTextRange {
            draftSelection = NSRange(location: field.offset(from: field.beginningOfDocument, to: range.start),
                                     length: field.offset(from: range.start, to: range.end))
        }
    }
    private func syncField() {
        guard let field = inputField else { return }
        syncingField = true; defer { syncingField = false }
        let selection = draftSelection
        field.text = draft
        if let start = field.position(from: field.beginningOfDocument, offset: selection.location),
           let end = field.position(from: start, offset: selection.length) { field.selectedTextRange = field.textRange(from: start, to: end) }
    }
    func clear() {
        if pending { connection.cancelQuestion() }
        generation = UUID(); answerTask?.cancel(); answerTask = nil; equalsTask?.cancel(); equalsTask = nil
        lastEquals = nil; sequence.reset(); snapshot = nil; draftSnapshot = nil
        pending = false; keyboard = false; ai = false; draft = ""; pages = []; page = 0; engine.clear()
        draftSelection = NSRange(location: 0, length: 0); syncField()
    }
    func edit() { if ai && !pending { keyboard = true } }
    func swipe(_ translation: CGSize) {
        if ai, translation.height > 35, abs(translation.height) > abs(translation.width) { keyboard = false; return }
        guard ai, !pending, abs(translation.width) > 35, abs(translation.width) > abs(translation.height) else { return }
        page = min(max(0, page + (translation.width < 0 ? 1 : -1)), max(0, pages.count - 1))
    }
    func sendDraft() {
        commitField()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ai, !pending, !text.isEmpty else { return }
        send(AIInput(text: text, image: nil, imageType: nil))
    }
    func paste() {
        // This is the ONLY clipboard read path: explicit long-press, AI mode, idle.
        guard ai, !pending else { return }
        do {
            if let image = UIPasteboard.general.image {
                guard image.size.width * image.scale <= 12_000, image.size.height * image.scale <= 12_000,
                      image.size.width * image.size.height * image.scale * image.scale <= 24_000_000 else { throw SafeFailure.tooLarge }
                let png = image.pngData()
                if let png, png.count <= 8_000_000 {
                    send(AIInput(text: "사진의 문제를 풀고 최종 답만 알려줘.", image: png, imageType: "image/png"))
                } else if let jpeg = image.jpegData(compressionQuality: 0.95), jpeg.count <= 8_000_000 {
                    send(AIInput(text: "사진의 문제를 풀고 최종 답만 알려줘.", image: jpeg, imageType: "image/jpeg"))
                } else { throw SafeFailure.tooLarge }
            } else if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                send(AIInput(text: text, image: nil, imageType: nil))
            }
        } catch { connection.recordFailure(error) }
    }
    private func send(_ input: AIInput) {
        guard ai, !pending else { return }
        draft = input.image == nil ? input.text : ""; draftSelection = NSRange(location: draft.utf16.count, length: 0); syncField()
        pending = true; keyboard = false; pages = []; page = 0
        let diagnosticID = connection.beginQuestion()
        let transaction = UUID(); generation = transaction
        answerTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == transaction { self.pending = false; self.answerTask = nil } }
            do {
                let text: String
                #if DEBUG
                if let responder = self.syntheticResponder { text = try await responder(input) }
                else { text = try await self.connection.answer(input, diagnosticID: diagnosticID) }
                #else
                text = try await self.connection.answer(input, diagnosticID: diagnosticID)
                #endif
                guard !Task.isCancelled, self.generation == transaction, self.ai else { return }
                self.pages = AnswerPages.split(text); self.page = 0
                self.connection.finishQuestion(diagnosticID)
            } catch {
                if self.generation == transaction { self.connection.finishQuestion(diagnosticID, error: error) }
            }
        }
    }
    #if DEBUG
    func syntheticChecks() async {
        if ProcessInfo.processInfo.arguments.contains("--calculator-render-check") {
            ai = true; pages = ["\\(\\displaystyle \\frac{1}{x}\\)"]; page = 0; return
        }
        if ProcessInfo.processInfo.arguments.contains("--calculator-draft-check") {
            ai = true; draft = "sin(30)의 값과 2²의 합을 알려줘"; syncField(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--calculator-number-check") {
            for key in ["1", "2", "3", "4", "5", ".", "6", "7"] { engine.press(key) }; return
        }
        guard ProcessInfo.processInfo.arguments.contains("--calculator-self-check") else { return }
        var passed = 0, errors: [String] = []
        func check(_ ok: Bool, _ label: String) { if ok { passed += 1 } else { errors.append(label) } }
        clear(); press("2"); press("+"); press("3"); press("=")
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(engine.value == 5, "normal equals")
        press("="); press("="); check(ai, "double equals enters")
        press("="); press("="); check(ai, "double equals idempotent")
        let saved = engine.entry; press("7"); press("+"); press("sin"); press("3"); press("0"); press("MS"); press("DEG")
        check(engine.entry == saved && !engine.hasMemory && engine.degrees && draft == "7+sin(30)", "AI keypad edits only question")
        let intact = draft; press("="); press("="); check(draft == intact, "AI reentry preserves typed formula")
        for key in CalculatorKeys.secret { press(key) }
        check(settings && draft == intact, "AI settings sequence restores question and caret"); settings = false
        press("CE"); check(draft.isEmpty && ai && answer == "0", "CE clears only AI question")
        press("1"); press("2"); press("⌫"); check(draft == "1", "AI keypad backspace")
        if let field = inputField {
            field.text = "한글 👨‍👩‍👧‍👦 질문"; fieldChanged(field)
            let at = "한글 👨‍👩‍👧‍👦 ".utf16.count
            if let start = field.position(from: field.beginningOfDocument, offset: at),
               let end = field.position(from: start, offset: 2) { field.selectedTextRange = field.textRange(from: start, to: end) }
            fieldChanged(field); press("ln")
            check(draft == "한글 👨‍👩‍👧‍👦 ln(질문)", "native field selection mixed Korean/emoji wraps correctly")
            field.text = "한글 "; field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            field.setMarkedText("조합", selectedRange: NSRange(location: 2, length: 0)); fieldChanged(field)
            check(draft.contains("조합"), "marked Korean is visible in draft")
            field.unmarkText(); fieldChanged(field); press("+")
            check(draft == "한글 조합+", "committed Korean preserved with keypad insertion")
        } else { check(false, "native keyboard field mounted") }
        edit(); check(keyboard, "AI keyboard opens")
        var count = 0
        syntheticResponder = { _ in count += 1; try await Task.sleep(nanoseconds: 120_000_000); return "\\(\\frac{1}{x}\\)\n2" }
        draft = "synthetic ln(x) derivative"; sendDraft(); sendDraft()
        let sentDraft = draft; press("9"); press("CE")
        check(pending && answer == "0" && !keyboard && draft == sentDraft, "pending 0 and duplicate/edit guard")
        try? await Task.sleep(nanoseconds: 220_000_000)
        check(!pending && pages.count == 2 && count == 1 && draft == sentDraft, "one request and final pages with question retained")
        swipe(CGSize(width: -70, height: 0)); check(answer == "2", "swipe next")
        swipe(CGSize(width: 70, height: 0)); check(answer.contains("frac"), "swipe previous")
        press("="); press("="); check(pages.count == 2, "AI reentry preserves answer")
        draft = "synthetic cancellation"; sendDraft(); clear()
        try? await Task.sleep(nanoseconds: 220_000_000)
        check(!ai && !pending && engine.display == "0" && pages.isEmpty, "C cancels stale response")
        check(connection.question.stage == "취소됨", "C records cancellation")
        press("="); press("=")
        syntheticResponder = { _ in throw ResponseIssue(reason: .missingCompletion) }
        draft = "synthetic response failure"; sendDraft()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let diagnosticID = connection.question.id, failure = connection.question.failure
        check(!pending && answer == "0" && connection.question.stage == "실패", "failed answer retains hidden 0")
        connection.recordFailure(SafeFailure.models)
        check(connection.question.id == diagnosticID && connection.question.failure == failure && failure != nil, "connection status cannot overwrite question error")
        clear(); press("="); press("=")
        syntheticResponder = { _ in "2" }; draft = "synthetic retry"; sendDraft()
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(answer == "2" && connection.question.stage == "완료" && connection.question.failure == nil, "new successful request resets prior error")
        clear(); check(!ai && engine.display == "0", "C idempotent")
        edit(); check(!keyboard, "normal double display does not edit")
        press("9"); let preserved = engine.entry
        for key in CalculatorKeys.secret { press(key) }
        check(settings && engine.entry == preserved, "settings sequence restores calculation")
        settings = false; clear(); syntheticResponder = nil
        let report = errors.isEmpty ? "PASS: \(passed) native-model synthetic checks; no real account/clipboard/network used." : "FAIL: " + errors.joined(separator: ", ")
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.write(to: folder.appendingPathComponent("mock-app-checks.txt"), atomically: true, encoding: .utf8)
        }
    }
    #endif
}

@main struct ScientificCalculatorApp: App {
    @StateObject private var model = CalculatorModel()
    var body: some Scene {
        WindowGroup {
            CalculatorScreen(model: model)
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    await model.syntheticChecks()
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.keyboard = false }
        }
    }
}

private extension Color {
    static let calculatorBackground = Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
    static let functionKey = Color(red: 50 / 255, green: 50 / 255, blue: 50 / 255)
    static let numberKey = Color(red: 59 / 255, green: 59 / 255, blue: 59 / 255)
    static let equalsKey = Color(red: 118 / 255, green: 185 / 255, blue: 237 / 255)
}

struct CalculatorScreen: View {
    @ObservedObject var model: CalculatorModel
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 600
            VStack(spacing: 0) {
                HStack { Text("공학용").font(.system(size: 20, weight: .semibold)); Spacer() }
                    .frame(height: compact ? 32 : 42).padding(.horizontal, 12)
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.ai ? model.draft : model.engine.expression)
                            .font(.system(size: model.ai ? 9 : 13)).foregroundStyle(.gray)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .trailing)
                            .accessibilityIdentifier("calculator-expression")
                        FormulaDisplay(text: model.ai ? model.answer : model.engine.display)
                            .accessibilityLabel(model.ai ? model.answer : model.engine.display)
                            .accessibilityIdentifier("calculator-display")
                    }.padding(12)
                    SendKeyboard(model: model)
                        .frame(width: 1, height: 1).opacity(0.02).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity).frame(height: compact ? 90 : 128)
                .contentShape(Rectangle())
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.paste() }
                    .exclusively(before: TapGesture(count: 2).onEnded { model.edit() }
                        .exclusively(before: TapGesture().onEnded { model.keyboard = false })))
                .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { model.swipe($0.translation) })
                HStack(spacing: 18) {
                    Button(model.engine.degrees ? "DEG" : "RAD") { model.press("DEG") }.accessibilityIdentifier("angle")
                    Text("삼각함수 · 로그 · 지수").foregroundStyle(Color.white.opacity(0.7))
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: compact ? 26 : 32)
                HStack(spacing: 0) {
                    ForEach(["MC", "MR", "M+", "M−", "MS", "M⌄"], id: \.self) { key in
                        Button { model.press(key) } label: { Text(key).font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                            .buttonStyle(.plain).accessibilityIdentifier("key-" + key)
                    }
                }.frame(height: compact ? 28 : 34)
                VStack(spacing: 3) {
                    ForEach(0..<CalculatorKeys.rows.count, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(CalculatorKeys.rows[row], id: \.self) { key in
                                Button { model.press(key) } label: {
                                    Text(key).font(.system(size: key.count == 1 && key.first!.isNumber ? 25 : 20, weight: .medium))
                                        .lineLimit(1).minimumScaleFactor(0.55).frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(CalculatorButtonStyle(key: key))
                                .accessibilityIdentifier("key-" + key)
                            }
                        }.frame(maxHeight: .infinity)
                    }
                }.padding(.bottom, 4)
            }
            .padding(.horizontal, 4).foregroundStyle(.white).background(Color.calculatorBackground)
        }
        .background(Color.calculatorBackground.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $model.settings) { ConnectionSettings(connection: model.connection) }
    }
}

struct CalculatorButtonStyle: ButtonStyle {
    let key: String
    func makeBody(configuration: Configuration) -> some View {
        let numeric = (key.count == 1 && key.first!.isNumber) || ["±", "."].contains(key)
        configuration.label
            .foregroundStyle(key == "=" ? Color.black : Color.white)
            .background((key == "=" ? Color.equalsKey : (numeric ? Color.numberKey : Color.functionKey)).opacity(configuration.isPressed ? 0.68 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct SendKeyboard: UIViewRepresentable {
    @ObservedObject var model: CalculatorModel
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let view = UITextField(); view.returnKeyType = .send; view.delegate = context.coordinator
        view.autocorrectionType = .no; view.spellCheckingType = .no; view.smartQuotesType = .no; view.smartDashesType = .no
        view.textColor = .clear; view.tintColor = .clear; view.keyboardAppearance = .dark
        view.inputAssistantItem.leadingBarButtonGroups = []; view.inputAssistantItem.trailingBarButtonGroups = []
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        model.inputField = view
        return view
    }
    func updateUIView(_ view: UITextField, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil, view.text != model.draft { view.text = model.draft }
        if model.keyboard, !view.isFirstResponder { DispatchQueue.main.async { if context.coordinator.parent.model.keyboard { view.becomeFirstResponder() } } }
        if !model.keyboard, view.isFirstResponder { view.resignFirstResponder() }
    }
    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SendKeyboard
        init(_ parent: SendKeyboard) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.model.fieldChanged(field) }
        func textFieldDidChangeSelection(_ field: UITextField) { parent.model.fieldChanged(field) }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.unmarkText(); parent.model.fieldChanged(field)
            DispatchQueue.main.async { self.parent.model.sendDraft() }; return false
        }
        func textFieldDidEndEditing(_ field: UITextField) { parent.model.keyboard = false }
    }
}

struct FormulaDisplay: UIViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false; web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web; context.coordinator.text = text
        if let html = Bundle.main.url(forResource: "Renderer", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.text = text; context.coordinator.render() }
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var text = "0", loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true; render()
            #if DEBUG
            let mathCheck = ProcessInfo.processInfo.arguments.contains("--calculator-render-check")
            let numberCheck = ProcessInfo.processInfo.arguments.contains("--calculator-number-check")
            if mathCheck || numberCheck {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let restore = numberCheck ? "12345.67" : "\\(\\displaystyle \\frac{1}{x}\\)"
                    let serialized = try! String(data: JSONSerialization.data(withJSONObject: [restore]), encoding: .utf8)!
                    let script = """
                    (() => {
                      const a=document.getElementById('answer'),b=document.getElementById('box');
                      let ok=true;
                      for(const n of ['0','12.30','001.','-3','1e+28','123456789012345678']){
                        showAnswer(n);fit();ok=ok&&!!a.querySelector('.katex')&&a.getBoundingClientRect().width<=b.clientWidth+1;
                      }
                      showAnswer('12.30');const ordinary=getComputedStyle(a.querySelector('.katex')).fontFamily;
                      showAnswer('\\\\(12.30\\\\)');ok=ok&&getComputedStyle(a.querySelector('.katex')).fontFamily===ordinary;
                      showAnswer('<img src=x onerror=alert(1)>');ok=ok&&!a.querySelector('img');
                      showAnswer((\(serialized))[0]);fit();
                      return ok&&!!a.querySelector('.katex')&&a.getBoundingClientRect().width<=b.clientWidth+1
                        &&a.getBoundingClientRect().height<=b.clientHeight+1\(mathCheck ? "&&!!a.querySelector('.mfrac')" : "");
                    })()
                    """
                    webView.evaluateJavaScript(script) { value, error in
                        let report = error == nil && value as? Bool == true ? "PASS: offline shared KaTeX numeric/font/fit/safe-text checks; final display rendered." : "FAIL: offline shared renderer"
                        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? report.write(to: folder.appendingPathComponent(numberCheck ? "number-render-check.txt" : "math-render-check.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            #endif
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func render() {
            guard loaded, let bytes = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: bytes, encoding: .utf8) else { return }
            web?.evaluateJavaScript("showAnswer((\(json))[0])", completionHandler: nil)
        }
    }
}

struct ConnectionSettings: View {
    @ObservedObject var connection: ChatGPTConnection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("ChatGPT 연결") {
                    if !connection.accounts.isEmpty {
                        Picker("계정", selection: Binding(get: { connection.selectedID ?? "" }, set: { connection.selectAccount($0) })) {
                            ForEach(connection.accounts) { account in Text(account.label).tag(account.id) }
                        }
                    }
                    Button(connection.selected == nil ? "ChatGPT로 로그인" : "선택한 계정 다시 로그인") { connection.login() }.disabled(connection.busy)
                    if connection.selected != nil { Button("다른 계정 추가") { connection.login(asNewAccount: true) }.disabled(connection.busy) }
                    if connection.busy { Button("로그인 대기 취소", role: .cancel) { connection.cancelLogin() } }
                    Text("공식 Safari 로그인을 사용합니다. 로그인 후 이 앱으로 돌아오세요. 실제 계정 연결은 아이폰에서 확인해야 합니다.").font(.footnote)
                }
                if connection.selected != nil {
                    Section("모델") {
                        if !connection.models.isEmpty {
                            Picker("사용할 모델", selection: Binding(get: { connection.selectedModel ?? "" }, set: connection.chooseModel)) {
                                ForEach(connection.models) { model in Text(model.display_name).tag(model.slug) }
                            }
                        }
                        Button("이 계정의 모델 목록 새로고침") { Task { await connection.loadModels() } }.disabled(connection.busy)
                        Button("이 기기에서 계정 연결 해제", role: .destructive) { connection.disconnect() }
                    }
                }
                Section("연결·모델 상태") { Text(connection.status).font(.footnote).textSelection(.enabled) }
                Section("최근 AI 요청") {
                    Text(connection.question.stage).fontWeight(.semibold)
                    if let started = connection.question.started {
                        Text("전송 시작: " + started.formatted(date: .omitted, time: .standard))
                        if let status = connection.question.httpStatus { Text("HTTP: \(status)") }
                        if let type = connection.question.mediaType { Text("응답 헤더: " + type) }
                        if let shape = connection.question.bodyShape { Text("본문 판별: " + shape) }
                        Text("수신: \(connection.question.bytes)바이트 · 이벤트 \(connection.question.events)개")
                        if let event = connection.question.lastEvent { Text("마지막 이벤트: " + event) }
                        if let failure = connection.question.failure { Text(failure).foregroundStyle(.orange) }
                        if let request = connection.question.requestID { Text("요청 ID: " + request) }
                    }
                    Text("질문·사진·답변·로그인 비밀은 진단 기록에 포함하지 않습니다. 이 기록은 앱 메모리에만 남고 모델 조회로 덮어쓰지 않습니다.")
                }.font(.footnote).textSelection(.enabled)
                Section("앱 버전") { Text("공학용 계산기 1.0.3 · 글꼴 통일·질문 표시·수식 입력") }.font(.footnote)
                Section("사용량·개인정보") {
                    Text("AI는 ChatGPT 플랜의 사용량·한도를 공유합니다. 별도의 무료 무제한 사용권이 아닙니다. API 요금 결제나 키 입력은 하지 않습니다.")
                    Text("계정 토큰은 이 기기의 Keychain에만 저장합니다. 질문과 사진은 전송할 때 OpenAI로 직접 보냅니다. 대화는 앱 메모리에만 있으며 서버 저장은 요청하지 않습니다. 앱 자체 분석·광고·원격 로그는 없습니다.")
                    Text("숨은 제스처는 잠금이나 보안 장치가 아닙니다. 기기를 쓰는 다른 사람도 발견하면 연결된 계정을 사용할 수 있습니다.")
                    Link("ChatGPT 계정·앱 권한 관리", destination: URL(string: "https://chatgpt.com/#settings")!)
                    Link("공개 소스·검증 범위", destination: URL(string: "https://github.com/leeqmin/calculatorai-ios-probe")!)
                }.font(.footnote)
                Section("조작") {
                    Text("= 두 번: AI 진입 · C: 취소하고 계산기로\nAI에서 숫자·함수 버튼: 질문에 수식 입력 · CE: 질문 비우기 · ⌫: 한 글자 지우기\nAI에서 화면 두 번: 키보드 · 길게: 텍스트/사진 붙여넣고 전송\n위쪽 작은 줄: 질문·수식 미리보기(길면 끝부분 표시)\n키보드 전송: 질문 보내기 · 화면 한 번/아래 스와이프: 키보드 닫기\n화면 좌우 스와이프: 답 넘기기\n설정: ln → n! → mod → ln (4초 이내)").font(.footnote)
                }
            }
            .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .alert("ChatGPT 플랜 사용", isPresented: $connection.showUsageNotice) {
                Button("확인") { connection.acknowledgeUsage() }
            } message: { Text("이 앱의 AI 요청은 연결한 ChatGPT 플랜의 사용량을 사용하며 해당 한도가 적용됩니다. 최초 로그인·실제 AI 동작은 이 기기에서 확인하세요.") }
            .task { if connection.selected != nil, connection.models.isEmpty { await connection.loadModels() } }
        }
    }
}

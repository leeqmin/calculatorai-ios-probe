import Foundation

enum ConnectionPhase: String {
    case signIn = "로그인", keys = "로그인 검증", refresh = "로그인 갱신"
    case models = "모델 목록 조회", response = "질문 응답"
}

enum RecoveryAction: String {
    case signIn, clientConfiguration, permission, wait, usage, model, request, inspect
    var message: String {
        switch self {
        case .signIn: return "로그인 인증이 만료되거나 취소됐습니다. 설정에서 다시 로그인하세요."
        case .clientConfiguration: return "앱의 로그인 등록 정보를 확인해야 합니다. 반복 로그인 대신 앱 업데이트 여부를 확인하세요."
        case .permission: return "계정·지역·앱 권한을 확인해야 합니다. 같은 요청이나 로그인을 반복하지 마세요."
        case .wait: return "서버 또는 연결을 일시적으로 사용할 수 없습니다. 계정은 유지됩니다. 잠시 후 직접 다시 시도하세요."
        case .usage: return "사용량 한도 또는 요청 제한입니다. ChatGPT 설정의 사용량을 확인하고 나중에 다시 시도하세요."
        case .model: return "이 모델로 요청할 수 없습니다. 설정에서 모델 목록을 확인하고 사용할 모델을 선택하세요. 질문은 자동 재전송하지 않습니다."
        case .request: return "현재 요청의 기능이나 형식을 지원하지 않습니다. 입력·모델을 확인하세요. 같은 요청은 자동 재전송하지 않습니다."
        case .inspect: return "연결 응답을 확인하지 못했습니다. 설정의 최근 연결 오류를 확인하세요."
        }
    }
}

// No raw body, error message, URL, account, question or credential is retained.
struct ConnectionIssue: Error {
    let phase: ConnectionPhase
    var httpStatus: Int?
    var code: String?
    var parameter: String?
    var requestID: String?
    var mediaType: String?
    var bodyShape: String?
    var reason: String?
    var action: RecoveryAction

    var message: String { phase.rawValue + ": " + action.message }
    var diagnostic: String {
        var parts = [message]
        if let reason { parts.append(reason) }
        if let httpStatus { parts.append("HTTP: \(httpStatus)") }
        if let code { parts.append("코드: " + code) }
        if let parameter { parts.append("항목: " + parameter) }
        if let mediaType { parts.append("응답 헤더: " + mediaType) }
        if let bodyShape { parts.append("응답 구조: " + bodyShape) }
        if let requestID { parts.append("요청 ID: " + requestID) }
        return parts.joined(separator: " · ")
    }
    var invalidatesTokens: Bool { phase == .refresh && action == .signIn }
    static func action(phase: ConnectionPhase, status: Int?, code: String?, parameter: String?) -> RecoveryAction {
        if phase == .refresh, ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                              "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") { return .signIn }
        if code == "invalid_client" { return .clientConfiguration }
        if ["model_not_found", "model_not_available", "model_access_denied", "invalid_model"].contains(code ?? "") { return .model }
        if code == "subscription_sharing_unsupported_capability" { return parameter == "model" ? .model : .request }
        if code == "subscription_sharing_route_not_supported" { return .request }
        if code == "subscription_sharing_usage_limit_exceeded" || status == 429 { return .usage }
        if ["subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"].contains(code ?? "") || (status ?? 0) >= 500 { return .wait }
        if [401, 403].contains(status ?? 0) || ["subscription_sharing_user_not_eligible", "subscription_sharing_invalid_user",
            "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context"].contains(code ?? "") { return .permission }
        return status == 400 ? .request : .inspect
    }
    static func http(_ response: HTTPURLResponse, body: Data, phase: ConnectionPhase) -> ConnectionIssue {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let nested = object?["error"] as? [String: Any]
        // OAuth uses a string error, while Responses normally uses error.code.
        let code = DiagnosticMetadata.identifier(nested?["code"] ?? object?["error"] ?? object?["code"])
        let parameter = DiagnosticMetadata.identifier(nested?["param"] ?? object?["param"])
        let shape = nested != nil || object?["error"] is String ? "error" : (object?["detail"] != nil ? "detail" : DiagnosticMetadata.bodyShape(body, final: true))
        return ConnectionIssue(phase: phase, httpStatus: response.statusCode, code: code, parameter: parameter,
            requestID: DiagnosticMetadata.requestID(response.value(forHTTPHeaderField: "x-request-id")),
            mediaType: DiagnosticMetadata.mediaType(response.value(forHTTPHeaderField: "Content-Type")), bodyShape: shape,
            action: action(phase: phase, status: response.statusCode, code: code, parameter: parameter))
    }
    static func response(_ issue: ResponseIssue, header: HTTPURLResponse) -> ConnectionIssue {
        var result = http(header, body: Data(), phase: .response)
        result.code = issue.code; result.parameter = issue.parameter; result.bodyShape = issue.bodyShape
        result.reason = issue.reason.rawValue
        result.action = action(phase: .response, status: header.statusCode, code: issue.code, parameter: issue.parameter)
        return result
    }
}

// Dependency boundary for synthetic tests; production uses the same Keychain keys.
// Test storage never opens Keychain, and no test exchanges real OAuth credentials.
struct ConnectionStorage {
    var read: (String) throws -> Data?
    var write: (Data, String) throws -> Void
}

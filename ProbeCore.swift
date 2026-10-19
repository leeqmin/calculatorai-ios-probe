import Foundation

// Deliberately accepts synthetic probe values only. Not an OAuth implementation.
enum ProbeError: Error { case invalidRequest, expired, wrongState, replay }

struct ProbeRequest {
    let path: String
    let query: [String: String]

    init(_ header: String, port: UInt16) throws {
        guard header.utf8.count <= 8192 else { throw ProbeError.invalidRequest }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
              let url = URLComponents(string: "http://127.0.0.1:\(port)\(first[1])"),
              url.fragment == nil else { throw ProbeError.invalidRequest }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "host" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard hosts == ["127.0.0.1:\(port)"] else { throw ProbeError.invalidRequest }
        var values: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else {
                throw ProbeError.invalidRequest
            }
            values[item.name] = value
        }
        path = url.path
        query = values
    }
}

struct ProbeTransaction {
    let state: String
    let started: Date
    private(set) var consumed = false

    init(state: String = UUID().uuidString + UUID().uuidString, started: Date = Date()) {
        self.state = state
        self.started = started
    }

    mutating func consume(_ request: ProbeRequest, now: Date = Date()) throws {
        guard !consumed else { throw ProbeError.replay }
        guard now.timeIntervalSince(started) >= 0, now.timeIntervalSince(started) <= 120 else {
            throw ProbeError.expired
        }
        guard request.path == "/auth/callback",
              Set(request.query.keys) == Set(["state", "code", "client_id"]),
              request.query["code"] == "probe-only",
              request.query["client_id"] == "probe-client" else { throw ProbeError.invalidRequest }
        guard request.query["state"] == state else { throw ProbeError.wrongState }
        consumed = true
    }
}

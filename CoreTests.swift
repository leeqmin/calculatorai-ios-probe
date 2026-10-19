import Foundation

@main
struct CoreTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1000)
        func request(_ target: String, host: String = "127.0.0.1:1455") throws -> ProbeRequest {
            try ProbeRequest("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n", port: 1455)
        }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError("Unexpected acceptance: \(name)") }
            catch { print("PASS \(name)") }
        }
        let valid = try request("/auth/callback?state=test&code=probe-only&client_id=probe-client")
        var transaction = ProbeTransaction(state: "test", started: now)
        try transaction.consume(valid, now: now)
        precondition(transaction.consumed)
        print("PASS synthetic callback")
        rejects("replay") { try transaction.consume(valid, now: now) }
        rejects("expiry") {
            var t = ProbeTransaction(state: "test", started: now)
            try t.consume(valid, now: now.addingTimeInterval(121))
        }
        rejects("wrong state") {
            var t = ProbeTransaction(state: "other", started: now)
            try t.consume(valid, now: now)
        }
        rejects("wrong host") { _ = try request("/probe", host: "attacker.example") }
        rejects("duplicate query") { _ = try request("/probe?state=a&state=b") }
        rejects("absolute target") { _ = try request("http://attacker.example/probe") }
        rejects("real code not supported") {
            var t = ProbeTransaction(state: "test", started: now)
            try t.consume(request("/auth/callback?state=test&code=real-code&client_id=probe-client"), now: now)
        }
        rejects("unknown parameter") {
            var t = ProbeTransaction(state: "test", started: now)
            try t.consume(request("/auth/callback?state=test&code=probe-only&client_id=probe-client&extra=1"), now: now)
        }
        rejects("oversized header") { _ = try request("/" + String(repeating: "a", count: 8192)) }
        print("10 core checks passed; these do not test iOS runtime or OAuth.")
    }
}

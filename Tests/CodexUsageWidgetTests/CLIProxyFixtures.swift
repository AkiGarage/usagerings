import Foundation
@testable import CodexUsageWidget

// Entirely synthetic; never read the real Keychain or contact CLIProxyAPI in tests.
enum CLIProxyFixtures {
    static let credentials = #"{"files":[{"provider":"claude","auth_index":"c1","email":"alice@example.test"},{"type":"claude","authIndex":"c2","email":"bobby@sample.test"},{"provider":"antigravity","auth_index":"a1","metadata":{"project_id":"fixture-project"}},{"provider":"claude","auth_index":"disabled","disabled":true}]}"#
    static let claude = #"{"five_hour":{"utilization":21,"resets_at":"2026-10-17T15:00:00Z"},"seven_day":{"utilization":36,"resets_at":"2026-10-22T00:00:00.000Z"}}"#
    static let antigravity = #"{"groups":[{"displayName":"Other","buckets":[{"window":"Daily","remainingFraction":0.9}]},{"displayName":"Gemini 3.8 Flash","buckets":[{"displayName":"5h","remainingFraction":0.93}]},{"displayName":"Gemini 4 Argon","buckets":[{"displayName":"5h","remainingFraction":0.86,"resetTime":"2026-10-17T15:00:00Z"}]}]}"#
    static func envelope(_ body: String, status: Int = 200, stringBody: Bool = true) -> Data {
        let value: Any = stringBody ? body : try! JSONSerialization.jsonObject(with: Data(body.utf8))
        return try! JSONSerialization.data(withJSONObject: ["status_code": status, "header": [:], "body": value])
    }
    static func client() -> CLIProxyClient {
        CLIProxyClient(transport: FixtureCLIProxyTransport(), keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
    }
}

struct FixtureCLIProxyKey: CLIProxyKeyProvider {
    // Random per fixture instance, never an actual management key or recorded request.
    let value: String? = UUID().uuidString
    func managementKey() -> String? { value }
}

struct FixtureCLIProxyPeerVerifier: CLIProxyPeerVerifier {
    var trusted = true
    func isTrustedListener() -> Bool { trusted }
}

struct FixtureCLIProxyTransport: CLIProxyTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "credentials" {
            return (Data(CLIProxyFixtures.credentials.utf8), 200)
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let isClaude = body["method"] as? String == "GET"
        return (CLIProxyFixtures.envelope(isClaude ? CLIProxyFixtures.claude : CLIProxyFixtures.antigravity, stringBody: isClaude), 200)
    }
}

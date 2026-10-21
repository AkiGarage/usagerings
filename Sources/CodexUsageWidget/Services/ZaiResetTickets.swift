import Foundation

enum ZaiResetTickets: Equatable, Sendable {
    struct Ticket: Equatable, Sendable {
        let title: String
        let available: Bool
        let expiresAt: Date
        /// Zoneless wall-clock string exactly as sent by Z.ai (nil when the API sent an explicit zone).
        var rawExpireTime: String? = nil
    }

    case loaded([Ticket])
    case unavailable

    enum InvalidResponse: Error { case invalid }

    /// Decode only display fields. Account identifiers and redeemable record IDs never enter the model.
    static func parse(_ data: Data) throws -> Self {
        struct Envelope: Decodable {
            let code: Int
            let success: Bool
            let data: Inventory
        }
        struct Inventory: Decodable {
            let fiveHourResets: [Record]
            let weekResets: [Record]
        }
        struct Record: Decodable {
            let available: Bool
            let expireTime: String
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.success, envelope.code == 200 else { throw InvalidResponse.invalid }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let chinaPlain = DateFormatter()
        chinaPlain.locale = Locale(identifier: "en_US_POSIX")
        chinaPlain.calendar = Calendar(identifier: .gregorian)
        chinaPlain.timeZone = TimeZone(identifier: "Asia/Shanghai")
        chinaPlain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        chinaPlain.isLenient = false
        func tickets(_ records: [Record], title: String) throws -> [Ticket] {
            try records.map { record in
                // Live API (checked 2026-10-21) sends "yyyy-MM-dd HH:mm:ss" with NO zone, and the zone is
                // UNVERIFIED: the web UI prints the string verbatim ("Valid until ${expireTime}"), docs give no
                // zone, and the account's credit-usage API reports timezone "Asia/Shanghai" (UTC+8).
                // Interpretation (2026-10-21): treat the zoneless string as China time (Asia/Shanghai, UTC+8).
                // The resulting instant drives both the JST display and the expiry comparison.
                let expiry: Date
                var raw: String? = nil
                if record.expireTime.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil,
                   let date = fractional.date(from: record.expireTime) ?? formatter.date(from: record.expireTime) {
                    expiry = date
                } else if record.expireTime.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                          let date = chinaPlain.date(from: record.expireTime) {
                    expiry = date
                    raw = record.expireTime
                } else { throw InvalidResponse.invalid }
                return Ticket(title: title, available: record.available, expiresAt: expiry, rawExpireTime: raw)
            }
        }
        return try .loaded(tickets(envelope.data.fiveHourResets, title: "5時間リセット")
                           + tickets(envelope.data.weekResets, title: "週リセット"))
    }
}

/// Prototype: fixed read-only destination, app-owned API key, no website session.
struct ZaiResetTicketClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    let loadKey: @Sendable () throws -> String
    let transport: Transport

    func fetch() async -> ZaiResetTickets {
        do {
            let key = try loadKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return .unavailable
            }
            var request = URLRequest(url: URL(string: "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, status) = try await transport(request)
            guard status == 200 else { return .unavailable }
            return try ZaiResetTickets.parse(data)
        } catch {
            return .unavailable
        }
    }

    static func live() -> Self {
        Self(loadKey: {
            struct Config: Decodable { let providers: [Provider] }
            struct Provider: Decodable {
                let id: String
                let apiKey: String?
                let region: String?
                let tokenAccounts: TokenAccounts?
            }
            struct TokenAccounts: Decodable { let accounts: [Account] }
            struct Account: Decodable {}
            // Match default CodexBar config precedence. Overrides/account selection need separate proof.
            let environment = ProcessInfo.processInfo.environment
            guard ["CODEXBAR_CONFIG", "Z_AI_API_HOST", "Z_AI_QUOTA_URL"].allSatisfy({ environment[$0] == nil }) else {
                throw ZaiResetTickets.InvalidResponse.invalid
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let paths = [".config/codexbar/config.json", ".codexbar/config.json"].map { home.appendingPathComponent($0) }
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ZaiResetTickets.InvalidResponse.invalid
            }
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: path))
            guard let provider = config.providers.first(where: { $0.id == "zai" }),
                  provider.region == nil || provider.region == "global",
                  provider.tokenAccounts?.accounts.isEmpty != false,
                  let key = provider.apiKey else { throw ZaiResetTickets.InvalidResponse.invalid }
            return key
        }, transport: { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        })
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

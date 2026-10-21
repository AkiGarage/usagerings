import CoreFoundation
import Foundation

public enum SyntheticFixtureExpectation: String, Codable, Equatable, Sendable {
    case success
    case structuredFailure
    case rejected
}

public struct CodexBarSyntheticFixture: Equatable, Sendable {
    public let name: String
    public let payload: Data
    public let exitCode: Int32
    public let expectation: SyntheticFixtureExpectation

    public init(name: String, payload: Data, exitCode: Int32, expectation: SyntheticFixtureExpectation) {
        self.name = name
        self.payload = payload
        self.exitCode = exitCode
        self.expectation = expectation
    }
}

public enum CompatibilityOutcome: String, Codable, Equatable, Sendable {
    case success
    case structuredFailure
}

public struct CompatibilityValidationResult: Codable, Equatable, Sendable {
    public let outcome: CompatibilityOutcome
    public let exitCode: Int32
    public let hasPrimary: Bool
    public let hasSecondary: Bool
    public let errorKind: String?
    public let errorCode: Int?
}

public struct CodexBarSyntheticContractValidator: Sendable {
    private static let knownErrorKinds: Set<String> = ["args", "config", "provider", "runtime"]

    public init() {}

    public func validate(_ data: Data, exitCode: Int32) throws -> CompatibilityValidationResult {
        guard !data.isEmpty, data.count <= 65_536,
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let entries = decoded as? [[String: Any]],
              let codex = entries.first(where: { $0["provider"] as? String == "codex" })
        else {
            throw ReleaseDetectionError.incompatibleContract
        }

        if exitCode != 0 {
            guard let error = codex["error"] as? [String: Any],
                  let code = Self.integer(error["code"])
            else {
                throw ReleaseDetectionError.incompatibleContract
            }
            let rawKind = error["kind"] as? String
            let kind = rawKind.flatMap { Self.knownErrorKinds.contains($0) ? $0 : nil }
            return CompatibilityValidationResult(
                outcome: .structuredFailure,
                exitCode: exitCode,
                hasPrimary: false,
                hasSecondary: false,
                errorKind: kind,
                errorCode: code
            )
        }

        guard codex["error"] == nil || codex["error"] is NSNull,
              let usage = codex["usage"] as? [String: Any]
        else {
            throw ReleaseDetectionError.incompatibleContract
        }

        let primary = try Self.validateWindow(named: "primary", in: usage)
        let secondary = try Self.validateWindow(named: "secondary", in: usage)
        guard primary || secondary else {
            throw ReleaseDetectionError.incompatibleContract
        }

        return CompatibilityValidationResult(
            outcome: .success,
            exitCode: exitCode,
            hasPrimary: primary,
            hasSecondary: secondary,
            errorKind: nil,
            errorCode: nil
        )
    }

    private static func validateWindow(named name: String, in usage: [String: Any]) throws -> Bool {
        guard let value = usage[name] else { return false }
        if value is NSNull { return false }
        guard let window = value as? [String: Any], isNumber(window["usedPercent"]) else {
            throw ReleaseDetectionError.incompatibleContract
        }
        return true
    }

    private static func isNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    private static func integer(_ value: Any?) -> Int? {
        guard isNumber(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double,
              double >= Double(Int.min), double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }
}

public enum CodexBarSyntheticFixtures {
    public static let all: [CodexBarSyntheticFixture] = [
        fixture("both-lanes", #"[{"provider":"codex","usage":{"primary":{"usedPercent":11},"secondary":{"usedPercent":22}}}]"#, .success),
        fixture("primary-only", #"[{"provider":"codex","usage":{"primary":{"usedPercent":11},"secondary":null}}]"#, .success),
        fixture("secondary-only", #"[{"provider":"codex","usage":{"primary":null,"secondary":{"usedPercent":22}}}]"#, .success),
        fixture("additive-fields", #"[{"provider":"synthetic-other","usage":{}},{"provider":"codex","futureEnvelope":{"enabled":true},"usage":{"primary":null,"secondary":{"usedPercent":22,"futureWindow":"ignored"},"futureUsage":[1]}}]"#, .success),
        fixture("structured-error", #"[{"provider":"codex","error":{"code":17,"kind":"provider","message":"synthetic-sensitive-message"}}]"#, .structuredFailure, exitCode: 1),
        fixture("missing-used-percent", #"[{"provider":"codex","usage":{"primary":{"remaining":89}}}]"#, .rejected),
        fixture("no-usable-lane", #"[{"provider":"codex","usage":{"primary":null,"secondary":null}}]"#, .rejected),
        fixture("missing-codex-entry", #"[{"provider":"synthetic-other","usage":{"primary":{"usedPercent":11}}}]"#, .rejected),
        fixture("wrong-envelope", #"{"provider":"codex","usage":{"primary":{"usedPercent":11}}}"#, .rejected),
        fixture("renamed-required-field", #"[{"provider":"codex","usage":{"primary":{"used_percentage":11}}}]"#, .rejected),
        fixture("wrong-required-type", #"[{"provider":"codex","usage":{"secondary":{"usedPercent":"22"}}}]"#, .rejected)
    ]

    public static func verify() throws {
        let validator = CodexBarSyntheticContractValidator()
        for fixture in all {
            do {
                let result = try validator.validate(fixture.payload, exitCode: fixture.exitCode)
                guard fixture.expectation != .rejected,
                      (fixture.expectation == .success && result.outcome == .success) ||
                        (fixture.expectation == .structuredFailure && result.outcome == .structuredFailure)
                else {
                    throw ReleaseDetectionError.incompatibleContract
                }
            } catch {
                guard fixture.expectation == .rejected else {
                    throw ReleaseDetectionError.incompatibleContract
                }
            }
        }
    }

    private static func fixture(
        _ name: String,
        _ json: String,
        _ expectation: SyntheticFixtureExpectation,
        exitCode: Int32 = 0
    ) -> CodexBarSyntheticFixture {
        CodexBarSyntheticFixture(
            name: name,
            payload: Data(json.utf8),
            exitCode: exitCode,
            expectation: expectation
        )
    }
}

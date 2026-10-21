import Foundation

public enum ReleaseDetectionError: LocalizedError, Equatable, Sendable {
    case invalidLedger
    case malformedResponse
    case invalidProvenance
    case paginationLoop
    case networkUnavailable
    case rateLimited
    case notFound
    case unexpectedHTTPStatus(Int)
    case ambiguousRelease(String)
    case identityMutation(String)
    case incompatibleContract
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case .invalidLedger:
            "The verified-release ledger is invalid"
        case .malformedResponse:
            "GitHub returned malformed release metadata"
        case .invalidProvenance:
            "CodexBar release provenance is invalid"
        case .paginationLoop:
            "GitHub release pagination did not terminate safely"
        case .networkUnavailable:
            "GitHub release discovery is temporarily unavailable"
        case .rateLimited:
            "GitHub release discovery is rate limited"
        case .notFound:
            "Required CodexBar release evidence was not found"
        case let .unexpectedHTTPStatus(status):
            "GitHub release discovery returned HTTP \(status)"
        case let .ambiguousRelease(tag):
            "CodexBar release identity is ambiguous for \(tag)"
        case let .identityMutation(tag):
            "Recorded CodexBar release identity changed for \(tag)"
        case .incompatibleContract:
            "CodexBar compatibility could not be proven"
        case .invalidArguments:
            "Invalid detector arguments"
        }
    }
}

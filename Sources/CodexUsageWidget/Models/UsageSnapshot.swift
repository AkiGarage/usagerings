import Foundation

struct UsageSnapshot: Equatable, Sendable {
    let session: UsageLimit?
    let weekly: UsageLimit?
    let updatedAt: Date

    var availableLimits: [UsageLimit] {
        [session, weekly].compactMap { $0 }
    }

    var primaryLimit: UsageLimit? {
        session ?? weekly
    }

    static let placeholder = UsageSnapshot(
        session: UsageLimit(title: "Session", leftPercent: 0, resetText: "Refreshing"),
        weekly: UsageLimit(title: "Weekly", leftPercent: 0, resetText: "Refreshing"),
        updatedAt: Date()
    )
}

struct UsageLimit: Equatable, Sendable {
    let title: String
    let leftPercent: Double
    let resetText: String
    let detailText: String?
    let projectionText: String?
    let markerPercent: Double?
    var accountIndex: Int? = nil
    /// Machine-readable reset time when the source reports one.
    var resetAt: Date? = nil
    /// Time the source actually obtained this value, including cached proxy values.
    var observedAt: Date? = nil

    // Observation age does not change the displayed limit's identity or values.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.leftPercent == rhs.leftPercent && lhs.resetText == rhs.resetText &&
        lhs.detailText == rhs.detailText && lhs.projectionText == rhs.projectionText &&
        lhs.markerPercent == rhs.markerPercent && lhs.accountIndex == rhs.accountIndex && lhs.resetAt == rhs.resetAt
    }

    init(
        title: String,
        leftPercent: Double,
        resetText: String,
        detailText: String? = nil,
        projectionText: String? = nil,
        markerPercent: Double? = nil
    ) {
        self.title = title
        self.leftPercent = leftPercent
        self.resetText = resetText
        self.detailText = detailText
        self.projectionText = projectionText
        self.markerPercent = markerPercent
    }

    var clampedLeftPercent: Double {
        min(max(leftPercent, 0), 100)
    }

    var leftText: String {
        "\(Int(clampedLeftPercent.rounded()))% left"
    }

    var tone: UsageTone {
        if clampedLeftPercent < 20 {
            return .critical
        }
        if clampedLeftPercent < 35 {
            return .warning
        }
        return .healthy
    }
}

enum UsageTone: Equatable, Sendable {
    case healthy
    case warning
    case critical
}

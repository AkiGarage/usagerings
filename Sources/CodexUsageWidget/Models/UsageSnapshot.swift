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

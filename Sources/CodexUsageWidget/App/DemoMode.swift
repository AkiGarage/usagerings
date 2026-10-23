import Foundation

/// Runtime boundary for demo data and preferences. The production case keeps
/// the existing defaults domain; demo mode always receives its own suite.
enum DemoMode {
    static let preferenceSuiteName = "com.akigarage.usagerings.demo"
    static let dummy8PreferenceSuiteName = "com.akigarage.usagerings.demo.dummy8"

    case production
    case demo(UserDefaults)

    var isEnabled: Bool {
        if case .demo = self { return true }
        return false
    }

    var defaults: UserDefaults {
        switch self {
        case .production: .standard
        case let .demo(defaults): defaults
        }
    }

    static func isolated(suiteName: String = preferenceSuiteName) throws -> Self {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw DemoLaunchError.preferencesUnavailable
        }
        return .demo(defaults)
    }
}

struct UsageRingsLaunchOptions: Equatable {
    let demoEnabled: Bool
    let showcase: Bool
    let exportDirectory: URL?
    /// Demo-only: open the hover card for this ring index (README screenshots).
    var hoverRing: Int? = nil
    var dummy8: Bool = false
    var shrinkDemo: Bool = false
    var shrinkDelay: TimeInterval = 0

    static func parse(arguments: [String], environment: [String: String]) throws -> Self {
        var requested = false
        var showcase = false
        var exportDirectory: URL?
        var hoverRing: Int?
        var dummy8 = false
        var shrinkDemo = false
        var shrinkDelay: TimeInterval = 0
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--usagerings-demo":
                requested = true
            case "--demo-showcase":
                requested = true
                showcase = true
            case "--demo-dummy8":
                requested = true
                dummy8 = true
            case "--demo-shrink":
                requested = true
                dummy8 = true
                shrinkDemo = true
            case "--demo-shrink-delay":
                guard index + 1 < arguments.count,
                      let delay = Double(arguments[index + 1]), delay.isFinite, delay >= 0 else {
                    throw DemoLaunchError.invalidShrinkDelay
                }
                index += 1
                requested = true
                dummy8 = true
                shrinkDemo = true
                shrinkDelay = delay
            case "--demo-hover-ring":
                guard index + 1 < arguments.count, let ring = Int(arguments[index + 1]), ring >= 0 else {
                    throw DemoLaunchError.invalidHoverRing
                }
                index += 1
                hoverRing = ring
                requested = true
            case "--demo-export":
                guard index + 1 < arguments.count else { throw DemoLaunchError.missingExportDirectory }
                index += 1
                let path = arguments[index]
                guard path.hasPrefix("/") else { throw DemoLaunchError.exportDirectoryMustBeAbsolute }
                exportDirectory = URL(fileURLWithPath: path, isDirectory: true)
                requested = true
            default:
                break
            }
            index += 1
        }
        let enabled = requested || environment["USAGERINGS_DEMO"] == "1"
        return Self(demoEnabled: enabled, showcase: showcase, exportDirectory: exportDirectory,
                    hoverRing: hoverRing, dummy8: dummy8, shrinkDemo: shrinkDemo,
                    shrinkDelay: shrinkDelay)
    }

    func makeMode(suiteName: String? = nil) throws -> DemoMode {
        guard demoEnabled else { return .production }
        let selectedSuite = suiteName ?? (dummy8 ? DemoMode.dummy8PreferenceSuiteName : DemoMode.preferenceSuiteName)
        return try DemoMode.isolated(suiteName: selectedSuite)
    }
}

enum DemoLaunchError: LocalizedError {
    case missingExportDirectory
    case invalidHoverRing
    case invalidShrinkDelay
    case exportDirectoryMustBeAbsolute
    case preferencesUnavailable
    case exportRequiresDemoMode
    case outputAlreadyExists(URL)
    case unableToRender(String)

    var errorDescription: String? {
        switch self {
        case .invalidShrinkDelay:
            "--demo-shrink-delay requires a non-negative number of seconds"
        case .invalidHoverRing:
            "--demo-hover-ring requires a non-negative ring index"
        case .missingExportDirectory:
            "--demo-export requires an absolute output directory"
        case .exportDirectoryMustBeAbsolute:
            "--demo-export directory must be an absolute path"
        case .preferencesUnavailable:
            "The isolated UsageRings demo preferences suite is unavailable"
        case .exportRequiresDemoMode:
            "Demo asset export requires demo mode"
        case let .outputAlreadyExists(url):
            "Refusing to overwrite existing demo asset: \(url.path)"
        case let .unableToRender(name):
            "Could not render demo asset: \(name)"
        }
    }
}

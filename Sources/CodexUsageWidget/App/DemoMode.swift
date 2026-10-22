import Foundation

/// Runtime boundary for demo data and preferences. The production case keeps
/// the existing defaults domain; demo mode always receives its own suite.
enum DemoMode {
    static let preferenceSuiteName = "com.akigarage.usagerings.demo"

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

    static func parse(arguments: [String], environment: [String: String]) throws -> Self {
        var requested = false
        var showcase = false
        var exportDirectory: URL?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--usagerings-demo":
                requested = true
            case "--demo-showcase":
                requested = true
                showcase = true
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
        return Self(demoEnabled: enabled, showcase: showcase, exportDirectory: exportDirectory)
    }

    func makeMode(suiteName: String = DemoMode.preferenceSuiteName) throws -> DemoMode {
        guard demoEnabled else { return .production }
        return try DemoMode.isolated(suiteName: suiteName)
    }
}

enum DemoLaunchError: LocalizedError {
    case missingExportDirectory
    case exportDirectoryMustBeAbsolute
    case preferencesUnavailable
    case exportRequiresDemoMode
    case outputAlreadyExists(URL)
    case unableToRender(String)

    var errorDescription: String? {
        switch self {
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

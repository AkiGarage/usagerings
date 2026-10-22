import Foundation

enum AppVariant: Equatable, Sendable {
    case single
    case multi

    static let classicBundleIdentifier = "local.codex.CodexUsageWidget"
    static let multiBundleIdentifier = "local.codex.CodexUsageWidgetMulti"
    /// Public release identity (UsageRings). Legacy ids above stay recognized.
    static let usageRingsBundleIdentifier = "com.akigarage.usagerings"

    static func current(bundleIdentifier: String?) -> AppVariant {
        // Multi has graduated into the classic /Applications identity.
        // Keep recognizing the Multi id for any side-by-side installs left over
        // during the transition.
        switch bundleIdentifier {
        case classicBundleIdentifier, multiBundleIdentifier, usageRingsBundleIdentifier:
            return .multi
        default:
            return .single
        }
    }
}

@MainActor
func makeAppPersona(for variant: AppVariant, demoMode: DemoMode = .production) -> any AppPersona {
    if demoMode.isEnabled {
        return MultiProviderPersona(demoMode: demoMode)
    }
    return switch variant {
    case .single:
        SingleProviderPersona()
    case .multi:
        MultiProviderPersona()
    }
}

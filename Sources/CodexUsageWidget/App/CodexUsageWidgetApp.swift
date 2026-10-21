import AppKit

@main
enum CodexUsageWidgetApp {
    static func main() {
        LegacySettingsMigration.runIfNeeded(bundleIdentifier: Bundle.main.bundleIdentifier)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

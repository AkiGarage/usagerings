import AppKit
import Darwin

@main
enum CodexUsageWidgetApp {
    static func main() {
        let options: UsageRingsLaunchOptions
        do {
            options = try UsageRingsLaunchOptions.parse(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }

        let mode: DemoMode
        do {
            mode = try options.makeMode()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }

        if !mode.isEnabled {
            LegacySettingsMigration.runIfNeeded(bundleIdentifier: Bundle.main.bundleIdentifier)
        }

        if mode.isEnabled, let specPath = DemoDummy8Exporter.specPath() {
            do {
                for file in try DemoDummy8Exporter.run(specPath: specPath) { print(file) }
                return
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        if let exportDirectory = options.exportDirectory {
            do {
                let files = try DemoSnapshotExporter.export(to: exportDirectory, mode: mode)
                for file in files { print(file.path) }
                return
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(demoMode: mode, showDemoShowcase: options.showcase,
                                   demoHoverRing: options.hoverRing, demoDummy8: options.dummy8,
                                   demoShrink: options.shrinkDemo, demoShrinkDelay: options.shrinkDelay)
        app.delegate = delegate
        app.run()
    }
}

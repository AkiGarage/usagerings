import AppKit
import Foundation

enum CodexBarRequirement {
    static let cliPath = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
    static let downloadURL = URL(string: "https://github.com/steipete/CodexBar/releases/latest")!

    static func isInstalled(
        path: String = cliPath,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }
}

enum CodexBarGate: Equatable, Sendable {
    case checking
    case ready
    case guide
    case deferred
}

enum CodexBarGateEvent: Equatable, Sendable {
    case probed(installed: Bool)
    case openDownload
    case later
}

enum CodexBarGateMachine {
    static func next(_ state: CodexBarGate, _ event: CodexBarGateEvent) -> CodexBarGate {
        switch (state, event) {
        case (.checking, .probed(let installed)),
             (.guide, .probed(let installed)):
            return installed ? .ready : .guide
        case (.guide, .openDownload),
             (.guide, .later):
            return .deferred
        default:
            return state
        }
    }

    static func showsGuide(_ state: CodexBarGate) -> Bool {
        state == .guide
    }
}

@MainActor
final class CodexBarGuideController {
    private(set) var state: CodexBarGate = .checking
    private let probe: () -> Bool
    private let openURL: (URL) -> Void
    private let ask: () -> NSApplication.ModalResponse

    init(
        probe: @escaping () -> Bool = { CodexBarRequirement.isInstalled() },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        ask: @escaping () -> NSApplication.ModalResponse = CodexBarGuideController.runAlert
    ) {
        self.probe = probe
        self.openURL = openURL
        self.ask = ask
    }

    func start() {
        send(.probed(installed: probe()))
        while CodexBarGateMachine.showsGuide(state) {
            switch ask() {
            case .alertFirstButtonReturn:
                openURL(CodexBarRequirement.downloadURL)
                send(.openDownload)
            case .alertSecondButtonReturn:
                send(.probed(installed: probe()))
            default:
                send(.later)
            }
        }
    }

    func send(_ event: CodexBarGateEvent) {
        state = CodexBarGateMachine.next(state, event)
    }

    static func runAlert() -> NSApplication.ModalResponse {
        let text = CodexBarGuideText.current()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: text.download)
        alert.addButton(withTitle: text.checkAgain)
        alert.addButton(withTitle: text.later)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

struct CodexBarGuideText: Equatable {
    let title: String
    let body: String
    let download: String
    let checkAgain: String
    let later: String

    static func current(languages: [String] = Locale.preferredLanguages) -> CodexBarGuideText {
        (languages.first ?? "").hasPrefix("ja") ? japanese : english
    }

    static let english = CodexBarGuideText(
        title: "UsageRings needs CodexBar",
        body: "UsageRings reads your usage through the free CodexBar app. Install CodexBar in the Applications folder, sign in to your AI services in CodexBar, then choose Check Again.",
        download: "Download CodexBar",
        checkAgain: "Check Again",
        later: "Later"
    )

    static let japanese = CodexBarGuideText(
        title: "UsageRingsにはCodexBarが必要です",
        body: "UsageRingsは無料のCodexBarアプリを通して使用量を読み取ります。CodexBarを「アプリケーション」フォルダに入れ、CodexBarで各AIサービスにログインしてから「もう一度確認」を押してください。",
        download: "CodexBarをダウンロード",
        checkAgain: "もう一度確認",
        later: "あとで"
    )
}

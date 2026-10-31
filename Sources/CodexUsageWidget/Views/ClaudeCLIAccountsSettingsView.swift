import SwiftUI

/// "Claude accounts": one CLAUDE_CONFIG_DIR per line, fetched with CodexBarCLI --source cli.
struct ClaudeCLIAccountsSettingsView: View {
    @State private var text = ClaudeCLIAccountSettings.format(ClaudeCLIAccountSettings.load())
    @State private var invalid = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude accounts").font(.subheadline.bold())
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
                .onChange(of: text) { _, _ in saved = false }
            HStack {
                Button("保存") {
                    let parsed = ClaudeCLIAccountSettings.parse(text)
                    let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
                    guard parsed.count == lines.count else { invalid = true; return }  // keep stored setting
                    invalid = false
                    ClaudeCLIAccountSettings.save(parsed)
                    text = ClaudeCLIAccountSettings.format(ClaudeCLIAccountSettings.load())
                    saved = true
                }
                Button("自動検出に戻す") {
                    ClaudeCLIAccountSettings.save([])
                    text = ClaudeCLIAccountSettings.format(ClaudeCLIAccountSettings.load())
                    saved = true
                }
                if invalid { Text("「名前 = フォルダ」の形でない行があります（未保存）").font(.caption).foregroundStyle(.red) }
                if saved { Text("次の更新で反映").font(.caption).foregroundStyle(.secondary) }
            }
            Text("1行に「名前 = フォルダ」。各フォルダを CLAUDE_CONFIG_DIR にして CodexBar CLI で使用量を読みます（中身は読みません）。~/.claude は通常のログインです。上から A, B…の順に表示します。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Acknowledgements").font(.headline)
            Text("UsageRings uses CodexBar (CodexBarCLI) by Peter Steinberger — https://github.com/steipete/CodexBar")
                .font(.caption).textSelection(.enabled)
            ScrollView {
                Text(Acknowledgements.codexBarLicense)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }
}

enum Acknowledgements {
    static let codexBarLicense = """
    MIT License

    Copyright (c) 2026 Peter Steinberger

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

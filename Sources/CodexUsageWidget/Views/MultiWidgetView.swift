import SwiftUI

struct MultiWidgetView: View {
    @ObservedObject var store: MultiUsageStore
    @ObservedObject var preferences: PanelPreferences
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MultiPanelContent(snapshot: store.snapshot, errorMessage: store.errorMessage,
                              preferences: preferences, claudeChoice: store.claudeChoice)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                        onContentSizeChange(size)
                    }
                })
        }
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: PanelBackground.cornerRadius, style: .continuous))
        .preferredColorScheme(preferences.appearance.colorScheme)
        .overlay(alignment: .topTrailing) {
            if let percent = store.opacityHUDPercent {
                OpacityHUDBadge(percent: percent).padding(6)
            }
        }
    }
}

struct PanelBackground: View {
    static let cornerRadius: CGFloat = 16
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        AdaptiveGlass(shape: shape)
    }
}

/// Refined dark glass: blurred backdrop darkened by ~74% graphite, 0.5pt top edge only.
/// No white film and no glow, so text stays crisp over light wallpapers.
struct LiquidGraphiteGlass<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(Color(red: 0.094, green: 0.102, blue: 0.122).opacity(0.74)))
            .overlay(shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.20), location: 0),
                                                               .init(color: .white.opacity(0.07), location: 0.12),
                                                               .init(color: .white.opacity(0.07), location: 1)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
    }
}

/// The same intrinsic content is used by the window and the offline snapshot harness.
struct MultiPanelContent: View {
    let snapshot: MultiUsageSnapshot
    var errorMessage: String?
    @ObservedObject var preferences: PanelPreferences
    var claudeChoice: ClaudeAccountPolicy.Decision? = nil
    static let baseWidth: CGFloat = 480
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSettings = false

    var body: some View {
        PanelZoomLayout(scale: preferences.zoom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text("残り使用量").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("更新 \(snapshot.updatedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    controls
                }
                .padding(.bottom, 2)
                ForEach(ServiceRowModel.rows(for: snapshot, showAccounts: preferences.showAccountNames,
                                             splitAntigravityAccounts: preferences.splitAntigravityAccounts,
                                             accountPreferences: preferences.accountPreferences)) { row in
                    ServiceRowView(row: row)
                }
                if let claudeChoice, let selected = claudeChoice.selected {
                    ClaudeChoiceLine(decision: claudeChoice, selected: selected)
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: Self.baseWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(preferences.zoom, anchor: .topLeading)
        }
        .preferredColorScheme(preferences.appearance.colorScheme)

    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button { preferences.zoomOut() } label: { Image(systemName: "minus") }
                .disabled(preferences.zoom <= PanelPreferences.zoomRange.lowerBound)
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            Button("\(preferences.percent)%") { preferences.resetZoom() }
                .monospacedDigit().frame(minWidth: 36)
                .help("Reset zoom to 100% (⌘0)")
                .accessibilityLabel("Reset zoom to 100 percent")
            Button { preferences.zoomIn() } label: { Image(systemName: "plus") }
                .disabled(preferences.zoom >= PanelPreferences.zoomRange.upperBound)
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
            Button { preferences.toggleAppearance(effective: colorScheme) } label: {
                Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
            }
            .help(appearanceAction)
            .accessibilityLabel(appearanceAction)
            Button { preferences.toggleOrientation() } label: {
                Image(systemName: preferences.orientation == .horizontal ? "rectangle.portrait" : "rectangle")
            }
            .help(orientationAction)
            .accessibilityLabel(orientationAction)
            Button { showsSettings.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .popover(isPresented: $showsSettings) {
                // Bind to the same suite as the panel: demo mode never reads or
                // writes the production SSH host.
                PanelSettingsView(preferences: preferences, snapshot: snapshot)
                    .defaultAppStorage(preferences.defaults)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .controlSize(.mini)
    }

    private var appearanceAction: String {
        colorScheme == .dark ? "Switch to light appearance" : "Switch to dark appearance"
    }

    private var orientationAction: String {
        preferences.orientation == .horizontal ? "Switch tab to vertical layout" : "Switch tab to horizontal layout"
    }
}

struct PanelSettingsView: View {
    @ObservedObject var preferences: PanelPreferences
    var snapshot: MultiUsageSnapshot = .placeholder
    @AppStorage(ClaudeSSHSettings.enabledKey) private var enabled = false
    @AppStorage(ClaudeSSHSettings.hostKey) private var host = ""

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Toggle("アカウント名を一部伏せて表示", isOn: $preferences.showAccountNames)
            Toggle("Antigravityをアカウント別に表示", isOn: $preferences.splitAntigravityAccounts)
            Divider()
            ProviderVisibilitySettingsView(preferences: preferences)
            Divider()
            Toggle("Claudeの使う順番を自動で決める（claude-ab）", isOn: $preferences.claudeAutoSwitch)
            Text("週の制限が先にリセットされる方を優先し、5時間制限中だけもう一方を使います。claude-a / claude-b のログイン中メールと一致したアカウントだけが対象です。オフにすると従来どおり a → b の順です。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            AccountSettingsView(snapshot: snapshot, preferences: preferences)
            Divider()
            Toggle("Read remote Claude B limits over SSH", isOn: $enabled)
            TextField("SSH host or user@host", text: $host)
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Text("Off by default. Uses your existing SSH setup and a trusted host key. Reads quota events from ~/.claude-b/projects on a Linux host; no passwords are stored here.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled && ClaudeSSHSettings(enabled: true, host: host) == nil {
                Text("Enter a hostname or user@hostname without spaces, ports, or SSH options.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("SSH changes apply on the next refresh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        }
        .frame(width: 390, height: 520)
    }
}

struct AccountSettingsView: View {
    let snapshot: MultiUsageSnapshot
    @ObservedObject var preferences: PanelPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("アカウント").font(.headline)
            Text("表示をオフにするとパネルとリングから隠れます。Primaryを選ぶと縮小表示はそのアカウントのリングだけになります。非表示・未取得時は表示中の先頭を使います。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Claude logsの警告はアカウントを特定できないため、表示・Primary設定と独立して表示します。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(snapshot.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.provider.displayName).font(.subheadline.bold())
                    Picker("Primary", selection: Binding(
                        get: { preferences.accountPreferences.primaryAccounts[section.provider.rawValue] ?? "" },
                        set: { preferences.setPrimaryAccount(AccountID(digest: $0), for: section.provider) }
                    )) {
                        Text("すべて表示").tag("")
                        ForEach(section.displayAccounts, id: \.index) { account in
                            if let id = account.id {
                                Text(accountName(account, in: section)).tag(id.rawValue)
                            }
                        }
                        if let saved = preferences.accountPreferences.primaryAccounts[section.provider.rawValue],
                           !section.displayAccounts.contains(where: { $0.id?.rawValue == saved }) {
                            Text("選択中のアカウント（未取得）").tag(saved)
                        }
                    }
                    ForEach(section.displayAccounts, id: \.index) { account in
                        if let id = account.id {
                            AccountSettingsRow(id: id, name: accountName(account, in: section), preferences: preferences)
                                .id(id)
                        } else {
                            Text("\(accountName(account, in: section))：識別情報がないため設定を保存できません")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func accountName(_ account: ProviderAccount, in section: ProviderSection) -> String {
        let base = "\(section.provider.displayName) \(ProviderSection.accountSuffix(account.index))"
        if let label = preferences.accountPreferences.label(for: account.id) { return "\(base) · \(label)" }
        if preferences.showAccountNames,
           let masked = ServiceRowModel.rows(for: section.forAccount(account.index), showAccounts: true).first?.account {
            return "\(base) · \(masked)"
        }
        return base
    }
}

struct AccountSettingsRow: View {
    let id: AccountID
    let name: String
    @ObservedObject var preferences: PanelPreferences
    @State private var label: String
    @FocusState private var labelFocused: Bool

    init(id: AccountID, name: String, preferences: PanelPreferences) {
        self.id = id
        self.name = name
        self.preferences = preferences
        _label = State(initialValue: preferences.accountPreferences.label(for: id) ?? "")
    }

    private func saveLabel() {
        if label != (preferences.accountPreferences.label(for: id) ?? "") {
            preferences.setAccountLabel(label, for: id)
        }
        label = preferences.accountPreferences.label(for: id) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(name, isOn: Binding(
                get: { preferences.accountPreferences.isVisible(id) },
                set: { preferences.setAccountVisible($0, for: id) }
            ))
            HStack {
                TextField("カスタムラベル", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(name)のラベル")
                    .focused($labelFocused)
                    .onSubmit { saveLabel() }
                    .onChange(of: labelFocused) { _, focused in
                        if !focused { saveLabel() }
                    }
                    .onChange(of: preferences.accountPreferences.label(for: id)) { _, stored in
                        label = stored ?? ""
                    }
                    .onChange(of: id) { _, _ in
                        label = preferences.accountPreferences.label(for: id) ?? ""
                    }
                Button("クリア") {
                    label = ""
                    saveLabel()
                }
                .disabled(label.isEmpty)
            }
        }
    }
}

/// scaleEffect alone does not change layout bounds. Report the scaled intrinsic
/// size as well, so both the scroll extent and native window fit the drawn pixels.
struct PanelZoomLayout: Layout {
    let scale: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

private struct MultiSectionView: View {
    let section: ProviderSection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.provider.displayName)
                .font(.system(size: 13, weight: .semibold))
            if let failureText = section.failureText {
                Text(failureText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(failureText)
            }
            ForEach(Array(section.windows.enumerated()), id: \.offset) { _, limit in
                MultiWindowRow(provider: section.provider, limit: limit)
            }
            ForEach(Array(section.stats.enumerated()), id: \.offset) { _, stat in
                let isInformational = stat.valueText == "No data" || stat.valueText == "No monthly cap"
                HStack(spacing: 8) {
                    Text(stat.title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(stat.valueText)
                        .monospacedDigit()
                        .foregroundStyle(isInformational ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stat.title): \(stat.valueText)")
            }
        }
    }
}

private struct MultiWindowRow: View {
    let provider: ProviderID
    let limit: UsageLimit

    private var bar: CollapsedUsageBar {
        let color: Color
        switch provider {
        case .codex: color = CollapsedUsageBar.codexColor
        case .claude: color = (limit.accountIndex ?? 0) == 0 ? CollapsedUsageBar.claudeAColor : CollapsedUsageBar.claudeBColor
        case .antigravity: color = CollapsedUsageBar.antigravityColor
        case .zai: color = CollapsedUsageBar.glmColor
        case .grok: color = CollapsedUsageBar.grokColor
        case .minimax, .kimi, .deepseek: color = ServiceRowModel.color(for: provider, account: 0)
        }
        return CollapsedUsageBar(id: limit.title, label: "", title: limit.title,
                                 providerColor: color, limit: limit)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limit.title).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(limit.resetText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(bar.providerColor.opacity(0.18))
                        Capsule().fill(LinearGradient(colors: [bar.fillColor.lighter(0.25), bar.fillColor],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: EdgeTabUsageBarLayout.fillWidth(
                                for: limit.clampedLeftPercent, in: proxy.size.width))
                        Capsule().strokeBorder(bar.isWarning ? bar.fillColor : .clear,
                                               lineWidth: bar.isWarning ? 1 : 0)
                    }
                }
                .frame(height: 7)
                Text(limit.leftText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Large rings, three per row, in the same order as the tablet. Details stay listed below.
private struct RingGrid: View {
    let snapshot: MultiUsageSnapshot

    var body: some View {
        Text("Usage left · \(snapshot.updatedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))")
            .font(.system(size: 11, weight: .semibold)).kerning(1.2).textCase(.uppercase)
            .foregroundStyle(.secondary)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 16) {
            ForEach(CollapsedUsageBar.bars(for: snapshot)) { bar in
                VStack(spacing: 4) {
                    UsageRing(bar: bar, lineWidth: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(bar.limit.map { "\(Int($0.clampedLeftPercent.rounded()))" } ?? "–")
                                .font(.system(size: 26, weight: .semibold))
                            if bar.limit != nil { Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                        }
                        .monospacedDigit()
                    }
                    .frame(width: 104, height: 104)
                    HStack(spacing: 4) {
                        Circle().fill(bar.providerColor).frame(width: 7, height: 7)
                        Text(bar.ringName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Text(bar.resetShort).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct ClaudeChoiceLine: View {
    let decision: ClaudeAccountPolicy.Decision
    let selected: String

    var title: String {
        let name = selected.count == 1 && selected == selected.lowercased() ? "claude-\(selected)" : "Claude \(selected)"
        return decision.state == .allLimited ? "Claudeは両方制限中：いまはCodexを使用（次は\(name)）" : "Claudeの切り替え：いまは\(name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(decision.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ProviderVisibilitySettingsView: View {
    @ObservedObject var preferences: PanelPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("表示するサービス").font(.headline)
            Text("契約しているもの・見たいものだけオンにします。オフにしたサービスは取得もしません。最初は、使用量が取れたサービスだけ自動でオンになります。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MultiUsageSnapshot.displayOrder) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { preferences.isProviderVisible(provider) },
                    set: { preferences.setProviderVisible($0, for: provider) }
                ))
            }
        }
    }
}

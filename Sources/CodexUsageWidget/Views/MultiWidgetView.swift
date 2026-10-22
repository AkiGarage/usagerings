import SwiftUI

struct MultiWidgetView: View {
    @ObservedObject var store: MultiUsageStore
    @ObservedObject var preferences: PanelPreferences
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MultiPanelContent(snapshot: store.snapshot, errorMessage: store.errorMessage,
                              preferences: preferences)
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
                ForEach(ServiceRowModel.rows(for: snapshot, showAccounts: preferences.showAccountNames)) { row in
                    ServiceRowView(row: row)
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
                ClaudeSSHSettingsView()
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

struct ClaudeSSHSettingsView: View {
    @AppStorage(ClaudeSSHSettings.enabledKey) private var enabled = false
    @AppStorage(ClaudeSSHSettings.hostKey) private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
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
            Text("Changes apply on the next refresh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
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

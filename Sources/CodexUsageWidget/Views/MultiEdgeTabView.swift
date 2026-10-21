import SwiftUI

struct MultiEdgeTabView: View {
    @ObservedObject var store: MultiUsageStore
    @ObservedObject var presentation: EdgeTabPresentationState
    @ObservedObject var preferences: PanelPreferences
    /// Ring-hover highlight driven by the tab's mouse tracking.
    @ObservedObject var ringHighlight: RingHighlightState
    private let opacityColor = Color(red: 0.08, green: 0.64, blue: 0.86)

    init(store: MultiUsageStore, presentation: EdgeTabPresentationState,
         preferences: PanelPreferences, ringHighlight: RingHighlightState = RingHighlightState()) {
        self.store = store
        self.presentation = presentation
        self.preferences = preferences
        self.ringHighlight = ringHighlight
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedLabel
            } else if let percent = store.opacityHUDPercent {
                let stack = preferences.orientation == .vertical
                    ? AnyLayout(VStackLayout(spacing: 2))
                    : AnyLayout(HStackLayout(spacing: 3))
                stack {
                    Text("OP")
                    Text("\(percent)%")
                }
                    .font(.system(size: max(8, 10 * preferences.barZoom), weight: .bold, design: .rounded))
                    .foregroundStyle(opacityColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.25)
            } else {
                collapsedSignal
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            if isExpanded {
                AdaptiveGlass(shape: Capsule(), tint: tabTint, intensity: .tabExpanded)
            } else {
                MultiCollapsedTabSurface()
            }
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
        .accessibilityLabel(accessibilityText)
        .onChange(of: store.snapshot, initial: true) {
            updateCollapsedSize()
        }
        .onChange(of: preferences.barZoom, initial: true) {
            updateCollapsedSize()
        }
        .onChange(of: preferences.orientation, initial: true) {
            updateCollapsedSize()
        }
        .onChange(of: presentation.menuBarHeight, initial: true) {
            updateCollapsedSize()
        }
    }

    private var expandedLabel: some View {
        Text("\(displayPercent)%")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .foregroundStyle(expandedTextColor)
            .shadow(color: .white.opacity(0.28), radius: 0.5, x: 0, y: 0.5)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collapsedSignal: some View {
        MultiCollapsedUsageView(snapshot: store.snapshot,
                                barZoom: preferences.barZoom,
                                menuBarHeight: presentation.menuBarHeight,
                                orientation: preferences.orientation,
                                highlightedBarID: ringHighlight.barID)
    }

    private var size: CGSize {
        presentation.size
    }

    private var isExpanded: Bool {
        presentation.mode == .expanded
    }

    private var isShowingOpacity: Bool {
        store.opacityHUDPercent != nil
    }

    private var displayPercent: Int {
        store.opacityHUDPercent
            ?? Int((store.snapshot.globalLowestWindow?.clampedLeftPercent ?? 0).rounded())
    }

    private var expandedTextColor: Color {
        if isShowingOpacity {
            return opacityColor
        }
        return .primary.opacity(0.94)
    }

    private var tabTint: Color {
        if isShowingOpacity {
            return opacityColor
        }
        return color(for: store.snapshot.globalLowestWindow?.tone ?? .critical)
    }

    private var accessibilityText: String {
        let providers = store.snapshot.sections.map { section in
            if let failureText = section.failureText {
                return "\(section.provider.displayName) \(failureText)"
            }
            let windows = section.windows.map {
                "\($0.title.lowercased()) \(Int($0.clampedLeftPercent.rounded()))% left"
            }
            return "\(section.provider.displayName) \(windows.joined(separator: ", "))"
        }
        return "Multi usage tab, \(providers.joined(separator: ", "))"
    }

    private func color(for tone: UsageTone) -> Color {
        switch tone {
        case .healthy:
            return Color(red: 0.20, green: 0.68, blue: 0.86)
        case .warning:
            return Color(red: 0.94, green: 0.62, blue: 0.10)
        case .critical:
            return Color(red: 0.90, green: 0.20, blue: 0.18)
        }
    }

    private func updateCollapsedSize() {
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: store.snapshot,
                                                                  barZoom: preferences.barZoom,
                                                                  menuBarHeight: presentation.menuBarHeight,
                                                                  orientation: preferences.orientation)
    }
}

struct MultiCollapsedTabSurface: View {
    var body: some View {
        // Neutral glass so color lives only in the rings (no cyan wash).
        AdaptiveGlass(shape: Capsule(), intensity: .tabCollapsed)
    }
}

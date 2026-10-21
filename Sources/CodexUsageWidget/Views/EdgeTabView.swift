import SwiftUI

enum EdgeTabPresentationMode: Equatable {
    case collapsed
    case expanded
    case dragging
}

enum EdgeTabPresentation {
    static let collapsedSize = CGSize(width: 52, height: 16)
    static let expandedSize = CGSize(width: 52, height: 30)

    static func size(for mode: EdgeTabPresentationMode) -> CGSize {
        switch mode {
        case .expanded:
            expandedSize
        case .collapsed, .dragging:
            collapsedSize
        }
    }
}

@MainActor
final class EdgeTabPresentationState: ObservableObject {
    @Published var mode: EdgeTabPresentationMode = .collapsed
    @Published var menuBarHeight: CGFloat = NSStatusBar.system.thickness
    @Published var collapsedSize = EdgeTabPresentation.collapsedSize {
        didSet {
            if collapsedSize != oldValue { onSizeChange?() }
        }
    }
    var onSizeChange: (() -> Void)?

    var size: CGSize {
        mode == .expanded
            ? CGSize(width: max(EdgeTabPresentation.expandedSize.width, collapsedSize.width),
                     height: max(EdgeTabPresentation.expandedSize.height, collapsedSize.height))
            : collapsedSize
    }
}

struct EdgeTabView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: EdgeTabPresentationState
    private let opacityColor = Color(red: 0.08, green: 0.64, blue: 0.86)

    var body: some View {
        Group {
            if isExpanded {
                expandedLabel
            } else {
                collapsedSignal
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            LiquidGlassSurface(
                shape: Capsule(),
                tint: tabTint,
                intensity: isExpanded ? .tabExpanded : .tabCollapsed
            )
        }
        .accessibilityLabel(accessibilityText)
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
        VStack(spacing: 2) {
            ForEach(store.snapshot.availableLimits, id: \.title) { limit in
                EdgeTabUsageBar(percent: limit.clampedLeftPercent, tone: limit.tone)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var size: CGSize {
        EdgeTabPresentation.size(for: presentation.mode)
    }

    private var isExpanded: Bool {
        presentation.mode == .expanded
    }

    private var isShowingOpacity: Bool {
        store.opacityHUDPercent != nil
    }

    private var displayPercent: Int {
        store.opacityHUDPercent ?? Int((store.snapshot.primaryLimit?.clampedLeftPercent ?? 0).rounded())
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
        return color(for: store.snapshot.primaryLimit?.tone ?? .critical)
    }

    private var accessibilityText: String {
        let limits = store.snapshot.availableLimits.map {
            "\($0.title.lowercased()) \(Int($0.clampedLeftPercent.rounded()))% left"
        }
        return "Codex usage tab, \(limits.joined(separator: ", "))"
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
}

struct EdgeTabUsageBar: View {
    let percent: Double?
    let tone: UsageTone?
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                LiquidGlassSurface(
                    shape: Capsule(),
                    tint: .white,
                    intensity: .barTrack
                )
                if let percent, let tone {
                    let filledWidth = EdgeTabUsageBarLayout.fillWidth(
                        for: percent,
                        in: width
                    )
                    if filledWidth > 0 {
                        Capsule()
                            .fill(color(for: tone).opacity(0.92))
                            .frame(width: filledWidth)
                            .shadow(color: color(for: tone).opacity(0.10), radius: 0.6, x: 0, y: 0)
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.white.opacity(0.10))
                                    .frame(height: 1)
                            }
                    }
                }
                Capsule()
                    .strokeBorder(.white.opacity(0.05), lineWidth: 0.4)
            }
        }
        .frame(height: height)
    }

    private func color(for tone: UsageTone) -> Color {
        switch tone {
        case .healthy:
            return Color(red: 0.12, green: 0.62, blue: 0.78)
        case .warning:
            return Color(red: 0.92, green: 0.58, blue: 0.05)
        case .critical:
            return Color(red: 0.86, green: 0.12, blue: 0.10)
        }
    }
}

enum EdgeTabUsageBarLayout {
    static let minimumVisibleFillWidth: CGFloat = 4

    static func fillWidth(for leftPercent: Double, in width: CGFloat) -> CGFloat {
        let clampedPercent = min(max(leftPercent, 0), 100)
        guard clampedPercent > 0, width > 0 else {
            return 0
        }

        let remainingWidth = width * CGFloat(clampedPercent / 100)
        return min(width, max(minimumVisibleFillWidth, remainingWidth))
    }
}

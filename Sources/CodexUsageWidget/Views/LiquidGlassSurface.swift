import SwiftUI

enum LiquidGlassIntensity {
    case tabCollapsed
    case tabExpanded
    case panel
    case hud
    case barTrack

    var material: Material {
        switch self {
        case .panel:
            return .ultraThinMaterial
        case .tabCollapsed, .tabExpanded, .hud, .barTrack:
            return .ultraThinMaterial
        }
    }

    var tintOpacity: Double {
        switch self {
        case .tabCollapsed:
            return 0.035
        case .tabExpanded:
            return 0.045
        case .panel:
            return 0.012
        case .hud:
            return 0.10
        case .barTrack:
            return 0.008
        }
    }

    var fallbackTintOpacity: Double {
        tintOpacity + 0.03
    }

    var highlightOpacity: Double {
        switch self {
        case .tabCollapsed:
            return 0.16
        case .tabExpanded, .hud:
            return 0.18
        case .panel:
            return 0.075
        case .barTrack:
            return 0.07
        }
    }

    var shadeOpacity: Double {
        switch self {
        case .panel:
            return 0
        case .barTrack:
            return 0
        case .tabCollapsed, .tabExpanded, .hud:
            return 0.018
        }
    }

    var rimOpacity: Double {
        switch self {
        case .panel:
            return 0.035
        case .barTrack:
            return 0.04
        case .tabCollapsed, .tabExpanded, .hud:
            return 0.12
        }
    }

    var innerRimOpacity: Double {
        switch self {
        case .panel:
            return 0.012
        case .barTrack:
            return 0.025
        case .tabCollapsed, .tabExpanded, .hud:
            return 0.045
        }
    }

    var rimLineWidth: CGFloat {
        switch self {
        case .panel:
            return 0.35
        case .barTrack:
            return 0.45
        case .tabCollapsed, .tabExpanded, .hud:
            return 0.55
        }
    }

    var innerRimLineWidth: CGFloat {
        switch self {
        case .panel:
            return 0.25
        case .barTrack:
            return 0.35
        case .tabCollapsed, .tabExpanded, .hud:
            return 0.45
        }
    }
}

struct LiquidGlassSurface<S: InsettableShape>: View {
    let shape: S
    let tint: Color
    let intensity: LiquidGlassIntensity

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        baseLayer
            .overlay(tintLayer)
            .overlay(specularHighlight)
            .overlay(depthShade)
            .overlay(outerRim)
            .overlay(innerRim)
    }

    @ViewBuilder
    private var baseLayer: some View {
        if reduceTransparency {
            shape.fill(fallbackBaseColor)
        } else {
            shape.fill(intensity.material)
        }
    }

    private var tintLayer: some View {
        shape.fill(tint.opacity(reduceTransparency ? intensity.fallbackTintOpacity : intensity.tintOpacity))
    }

    private var specularHighlight: some View {
        shape.fill(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(intensity.highlightOpacity), location: 0),
                    .init(color: .white.opacity(intensity.highlightOpacity * 0.26), location: 0.18),
                    .init(color: .clear, location: 0.42)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .blendMode(reduceTransparency ? .normal : .screen)
    }

    @ViewBuilder
    private var depthShade: some View {
        if intensity.shadeOpacity > 0 {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.74),
                        .init(color: .black.opacity(intensity.shadeOpacity), location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blendMode(reduceTransparency ? .normal : .multiply)
        }
    }

    private var outerRim: some View {
        shape.strokeBorder(
            Color.white.opacity(intensity.rimOpacity),
            lineWidth: intensity.rimLineWidth
        )
    }

    private var innerRim: some View {
        shape
            .inset(by: 1)
            .stroke(
                Color.primary.opacity(intensity.innerRimOpacity),
                lineWidth: intensity.innerRimLineWidth
            )
    }

    private var fallbackBaseColor: Color {
        if colorScheme == .dark {
            return Color(nsColor: .windowBackgroundColor).opacity(0.86)
        }
        return Color.white.opacity(0.88)
    }
}

/// Preserves graphite glass in dark appearance and uses native system glass
/// for light appearance where available.
struct AdaptiveGlass<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .primary
    var intensity: LiquidGlassIntensity = .panel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency, colorScheme == .light {
            shape.fill(.clear)
                .glassEffect(.regular.tint(tint.opacity(intensity.tintOpacity)), in: shape)
        } else {
            fallback
        }
#else
        fallback
#endif
    }

    @ViewBuilder
    private var fallback: some View {
        if reduceTransparency {
            shape.fill(opaqueFallbackColor)
        } else if colorScheme == .dark {
            if case .hud = intensity {
                // The detached hover card needs the panel's two-layer dark surface.
                LiquidGraphiteGlass(shape: shape)
                    .background(LiquidGraphiteGlass(shape: shape))
            } else {
                LiquidGraphiteGlass(shape: shape)
            }
        } else {
            LiquidGlassSurface(shape: shape, tint: tint, intensity: intensity)
        }
    }

    private var opaqueFallbackColor: Color {
        colorScheme == .dark
            ? Color(red: 0.094, green: 0.102, blue: 0.122)
            : .white
    }
}

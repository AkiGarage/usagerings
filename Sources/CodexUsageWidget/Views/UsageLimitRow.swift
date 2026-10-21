import SwiftUI

struct UsageLimitRow: View {
    let limit: UsageLimit
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(limit.title)
                .font(.system(size: 16 * scale, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            UsageBar(
                percent: limit.clampedLeftPercent,
                tone: limit.tone,
                markerPercent: limit.markerPercent,
                scale: scale
            )
                .frame(height: 8 * scale)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(limit.leftText)
                        .font(.system(size: 12 * scale, weight: .regular))
                        .lineLimit(1)
                    if let detailText = limit.detailText {
                        Text(detailText)
                            .font(.system(size: 11 * scale, weight: .regular))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12 * scale)

                VStack(alignment: .trailing, spacing: 2 * scale) {
                    Text(limit.resetText)
                        .font(.system(size: 12 * scale, weight: .regular))
                        .lineLimit(1)
                    if let projectionText = limit.projectionText {
                        Text(projectionText)
                            .font(.system(size: 11 * scale, weight: .regular))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageBar: View {
    let percent: Double
    let tone: UsageTone
    let markerPercent: Double?
    let scale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filledWidth = fillWidth(in: width)
            ZStack(alignment: .leading) {
                LiquidGlassSurface(
                    shape: Capsule(),
                    tint: .white,
                    intensity: .barTrack
                )
                if filledWidth > 0 {
                    Capsule()
                        .fill(fillGradient)
                        .frame(width: filledWidth)
                        .shadow(color: fillColor.opacity(0.12), radius: 1.0 * scale, x: 0, y: 0)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.white.opacity(0.12))
                                .frame(height: max(1, 1.2 * scale))
                        }
                    }
                tick(at: 0.20, width: width)
                tick(at: 0.50, width: width)
                if let markerPercent {
                    warningMarker(at: markerPercent, width: width)
                }
            }
        }
    }

    private var fillColor: Color {
        switch tone {
        case .healthy:
            return Color(red: 0.28, green: 0.73, blue: 0.86)
        case .warning:
            return Color(red: 0.96, green: 0.72, blue: 0.18)
        case .critical:
            return Color(red: 0.95, green: 0.24, blue: 0.20)
        }
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            colors: [
                fillColor.opacity(0.95),
                fillColor.opacity(0.82)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var markerColor: Color {
        Color(red: 0.95, green: 0.24, blue: 0.20)
    }

    private var markerGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(0.38),
                markerColor
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func tick(at position: Double, width: Double) -> some View {
        Capsule()
            .fill(.primary.opacity(0.26))
            .frame(width: max(1, scale), height: 4.5 * scale)
            .offset(x: width * position)
    }

    private func warningMarker(at percent: Double, width: Double) -> some View {
        let markerWidth = max(1, 2 * scale)
        let markerOffset = max(0, min(width - markerWidth, width * percent / 100))

        return Capsule()
            .fill(markerGradient)
            .frame(width: markerWidth, height: 8 * scale)
            .shadow(color: markerColor.opacity(0.18), radius: scale, x: 0, y: 0)
            .offset(x: markerOffset)
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        max(0, min(width, width * percent / 100))
    }
}

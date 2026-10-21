import SwiftUI

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    private let baseWidth: CGFloat = 360
    private let baseHeight: CGFloat = 190

    var body: some View {
        GeometryReader { proxy in
            let scale = layoutScale(for: proxy.size)

            VStack(alignment: .leading, spacing: 10 * scale) {
                ForEach(store.snapshot.availableLimits, id: \.title) { limit in
                    UsageLimitRow(limit: limit, scale: scale)
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10 * scale, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 10 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 180, idealWidth: baseWidth, maxWidth: .infinity, minHeight: 103, idealHeight: baseHeight, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LiquidGlassSurface(
                shape: RoundedRectangle(cornerRadius: 17, style: .continuous),
                tint: .white,
                intensity: .panel
            )
        }
        .overlay(alignment: .topTrailing) {
            if let opacityPercent = store.opacityHUDPercent {
                OpacityHUDBadge(percent: opacityPercent)
                    .padding(.top, 5)
                    .padding(.trailing, 6)
            }
        }
    }

    private func layoutScale(for size: CGSize) -> CGFloat {
        min(max(min(size.width / baseWidth, size.height / baseHeight), 0.5), 1.25)
    }
}

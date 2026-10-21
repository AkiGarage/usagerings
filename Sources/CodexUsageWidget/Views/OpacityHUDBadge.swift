import SwiftUI

struct OpacityHUDBadge: View {
    let percent: Int
    private let color = Color(red: 0.08, green: 0.64, blue: 0.86)

    var body: some View {
        Text("OP \(percent)%")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                LiquidGlassSurface(
                    shape: Capsule(),
                    tint: color,
                    intensity: .hud
                )
            }
    }
}

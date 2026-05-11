import SwiftUI

// MARK: - Matches Little Lamp (`ContentView`) chrome: soft gradient canvas + frosted cards.

struct ViewerBackgroundView: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LinearGradient(
      colors: colorScheme == .dark
        ? [
            Color(red: 0.09, green: 0.10, blue: 0.16),
            Color(red: 0.11, green: 0.09, blue: 0.14),
            Color(red: 0.08, green: 0.12, blue: 0.11),
          ]
        : [
            Color(red: 0.99, green: 0.93, blue: 0.97),
            Color(red: 0.93, green: 0.96, blue: 1.0),
            Color(red: 0.94, green: 0.99, blue: 0.96),
          ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
  }
}

struct ViewerGlassCard<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.ultraThinMaterial)
          .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
      )
  }
}

/// Glow orb synced to lamp `color` / power / blink — same vocabulary as Little Lamp preview.
struct FamilyLampGlowOrb: View {
  let colorHex: String
  let powerOn: Bool
  let blinkEnabled: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              (Color(hex: colorHex) ?? .pink).opacity(powerOn ? 0.95 : 0.26),
              (Color(hex: colorHex) ?? .purple).opacity(powerOn ? 0.36 : 0.12),
            ],
            center: .center,
            startRadius: 4,
            endRadius: 56
          )
        )
        .shadow(
          color: (Color(hex: colorHex) ?? .clear).opacity(powerOn ? 0.5 : 0.12),
          radius: powerOn ? 16 : 8,
          y: 6
        )

      Circle()
        .strokeBorder(.white.opacity(0.38), lineWidth: 2)

      Image(systemName: blinkEnabled ? "heart.circle.fill" : "sparkles")
        .font(.system(size: 28))
        .foregroundStyle(.white.opacity(0.92))
        .shadow(radius: 2)
        .opacity(powerOn ? 1 : 0.35)
    }
    .frame(width: 88, height: 88)
  }
}

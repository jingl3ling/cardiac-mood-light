import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var hub: MoodHub

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Cardiac Mood Light")
        .font(.title2.weight(.bold))

      HStack {
        Text(hub.authorizationStatus)
        if hub.watchSessionActive {
          Text("Watch linked")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(hex: hub.lastColorHex) ?? Color.gray.opacity(0.4))
          .frame(width: 56, height: 56)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))

        VStack(alignment: .leading, spacing: 4) {
          Text(hub.lastLabel)
            .font(.headline)
          Text(hub.lastMood)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if !hub.lastReason.isEmpty {
        Text(hub.lastReason)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      if !hub.lastUpdatedText.isEmpty {
        Text(hub.lastUpdatedText)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }

      if hub.isSending {
        ProgressView()
      }

      if !hub.lastError.isEmpty {
        Text(hub.lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Button("Authorize Health (resting HR)") {
        Task { await hub.authorizeHealthIfNeeded() }
      }
      .buttonStyle(.borderedProminent)

      Text("On the Watch, tap Start session. Each BPM window is sent here for analysis.")
        .font(.footnote)
        .foregroundStyle(.secondary)

      Text("ESP32 uses deviceId **\(Config.deviceId)** — must match Watch/phone `Config.deviceId`.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding()
    .task {
      await hub.authorizeHealthIfNeeded()
    }
  }
}

private extension Color {
  init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    self.init(red: r, green: g, blue: b)
  }
}

#Preview {
  ContentView()
    .environmentObject(MoodHub())
}

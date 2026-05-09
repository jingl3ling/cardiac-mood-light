import SwiftUI
import UIKit

/// Matches server `STYLE` in `cardiac_mood/main.py` (calm / stressed / happy / sad).
private struct MoodPreset: Identifiable {
  let id: String
  let title: String
  let caption: String
  let hex: String
  let symbol: String
}

private let moodPresets: [MoodPreset] = [
  MoodPreset(id: "calm", title: "Calm", caption: "Yellow · baseline", hex: "#FFD700", symbol: "leaf.fill"),
  MoodPreset(id: "stressed", title: "Stressed", caption: "Red · escalating", hex: "#FF0000", symbol: "bolt.heart.fill"),
  MoodPreset(id: "happy", title: "Happy", caption: "Pink · energetic", hex: "#FF69B4", symbol: "sun.max.fill"),
  MoodPreset(id: "sad", title: "Sad", caption: "Blue · drained", hex: "#4169E1", symbol: "cloud.rain.fill"),
]

private let validMoods = Set(moodPresets.map(\.id))

struct ContentView: View {
  @EnvironmentObject private var hub: MoodHub

  @State private var selectedMoodId = "calm"
  @State private var customColorEnabled = false
  @State private var customColor = Color(red: 1, green: 215 / 255, blue: 0)

  private var selectedPreset: MoodPreset {
    moodPresets.first { $0.id == selectedMoodId } ?? moodPresets[0]
  }

  private var previewHex: String {
    if customColorEnabled {
      return customColor.rgbHexString() ?? selectedPreset.hex
    }
    return selectedPreset.hex
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          lampPreviewCard

          VStack(alignment: .leading, spacing: 10) {
            Text("Mood")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
              ForEach(moodPresets) { preset in
                moodTile(preset, isSelected: preset.id == selectedMoodId)
              }
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Brightness")
                .font(.subheadline.weight(.semibold))
              Spacer()
              Text("\(Int(hub.lampBrightness.rounded()))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Slider(value: $hub.lampBrightness, in: 0 ... 255, step: 1)
              .tint(Color(hex: previewHex) ?? .accentColor)
          }
          .padding(16)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

          VStack(alignment: .leading, spacing: 12) {
            Toggle("Custom color", isOn: $customColorEnabled)
              .tint(.pink)
            if customColorEnabled {
              ColorPicker("Tint", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
            }
          }
          .padding(16)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

          Button {
            Task {
              await hub.pushManualLamp(
                mood: selectedMoodId,
                brightness: Int(hub.lampBrightness.rounded()),
                colorHexOverride: customColorEnabled ? customColor.rgbHexString() : nil
              )
            }
          } label: {
            Label("Update lamp", systemImage: "lightbulb.led.wide.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(hub.isSending)

          watchAndHealthSection
        }
        .padding()
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Mood light")
      .navigationBarTitleDisplayMode(.large)
    }
    .task {
      await hub.authorizeHealthIfNeeded()
    }
    .onAppear {
      if validMoods.contains(hub.lastMood) {
        selectedMoodId = hub.lastMood
      }
      if customColorEnabled {
        customColor = Color(hex: selectedPreset.hex) ?? customColor
      }
    }
    .onChange(of: selectedMoodId) { _, _ in
      if !customColorEnabled {
        customColor = Color(hex: selectedPreset.hex) ?? customColor
      }
    }
    .onChange(of: customColorEnabled) { _, enabled in
      if enabled {
        customColor = Color(hex: selectedPreset.hex) ?? customColor
      }
    }
  }

  private var lampPreviewCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 14) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color(hex: previewHex) ?? Color.gray.opacity(0.35))
          .frame(width: 72, height: 72)
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(.white.opacity(0.25), lineWidth: 1)
          }
          .shadow(color: (Color(hex: previewHex) ?? .clear).opacity(0.45), radius: 16, y: 6)

        VStack(alignment: .leading, spacing: 4) {
          Text(hub.lastLabel == "—" ? selectedPreset.title : hub.lastLabel)
            .font(.title3.weight(.semibold))
          Text(
            hub.lastUpdatedText.isEmpty
              ? "Choose a mood, adjust brightness, then update the lamp."
              : "Last sent \(hub.lastUpdatedText)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      if !hub.lastReason.isEmpty {
        Text(hub.lastReason)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      if hub.isSending {
        ProgressView()
          .padding(.top, 4)
      }
      if !hub.lastError.isEmpty {
        Text(hub.lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  @ViewBuilder
  private func moodTile(_ preset: MoodPreset, isSelected: Bool) -> some View {
    Button {
      selectedMoodId = preset.id
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: preset.symbol)
            .font(.title3)
            .foregroundStyle(Color(hex: preset.hex) ?? .primary)
          Spacer()
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.blue)
          }
        }
        Text(preset.title)
          .font(.headline)
          .foregroundStyle(.primary)
        Text(preset.caption)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isSelected ? Color.blue.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(isSelected ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 2)
      )
    }
    .buttonStyle(.plain)
  }

  private var watchAndHealthSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Heart rate")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

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

      Button("Authorize Health (resting HR)") {
        Task { await hub.authorizeHealthIfNeeded() }
      }
      .buttonStyle(.bordered)

      Text("On the Watch, tap Start session. Each BPM window is sent here for analysis and updates the lamp automatically.")
        .font(.footnote)
        .foregroundStyle(.secondary)

      Text("ESP32 polls device **\(Config.deviceId)** — match `DEVICE_ID` on the board.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

  func rgbHexString() -> String? {
    let ui = UIColor(self)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    return String(
      format: "#%02X%02X%02X",
      Int(round(r * 255)),
      Int(round(g * 255)),
      Int(round(b * 255))
    )
  }
}

#Preview {
  ContentView()
    .environmentObject(MoodHub())
}

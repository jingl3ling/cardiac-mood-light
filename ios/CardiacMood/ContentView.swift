import SwiftUI
import UIKit

/// Matches server `STYLE` in `cardiac_mood/main.py` (calm / stressed / happy / sad).
private struct MoodPreset: Identifiable {
  let id: String
  let title: String
  let hex: String
  let symbol: String
}

private let moodPresets: [MoodPreset] = [
  MoodPreset(id: "calm", title: "Calm", hex: "#FFD700", symbol: "leaf.fill"),
  MoodPreset(id: "stressed", title: "Stressed", hex: "#FF0000", symbol: "bolt.heart.fill"),
  MoodPreset(id: "happy", title: "Happy", hex: "#FF69B4", symbol: "sun.max.fill"),
  MoodPreset(id: "sad", title: "Sad", hex: "#4169E1", symbol: "cloud.rain.fill"),
]

private let validMoods = Set(moodPresets.map(\.id))

private let lampSyncDebounceNs: UInt64 = 260_000_000

struct ContentView: View {
  @EnvironmentObject private var hub: MoodHub

  @State private var selectedMoodId = "calm"
  @State private var customColorEnabled = false
  @State private var customColor = Color(red: 1, green: 215 / 255, blue: 0)
  @State private var debouncedLampTask: Task<Void, Never>?

  private var selectedPreset: MoodPreset {
    moodPresets.first { $0.id == selectedMoodId } ?? moodPresets[0]
  }

  private var previewHex: String {
    if customColorEnabled {
      return customColor.rgbHexString() ?? selectedPreset.hex
    }
    return selectedPreset.hex
  }

  private var brightnessSliderBinding: Binding<Double> {
    Binding(
      get: { hub.lampBrightness },
      set: { newValue in
        hub.lampBrightness = newValue
        scheduleLampSyncDebounced()
      }
    )
  }

  var body: some View {
    NavigationStack {
      ZStack {
        CuteBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            CuteCard {
              powerControlRow
            }

            CuteCard {
              lampPreviewRow
            }

            CuteCard {
              moodsAndBlinkSection
            }

            CuteCard {
              brightnessSection
            }

            CuteCard {
              customColorSection
            }

            CuteCard {
              watchAndHealthSection
            }
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 28)
        }
      }
      .navigationTitle("Little Lamp ✨")
      .navigationBarTitleDisplayMode(.large)
      .toolbarBackground(.visible, for: .navigationBar)
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
    .onDisappear {
      debouncedLampTask?.cancel()
      debouncedLampTask = nil
    }
  }

  private var powerControlRow: some View {
    HStack(spacing: 14) {
      Image(systemName: hub.lampPowerOn ? "power.circle.fill" : "power.circle")
        .font(.system(size: 32))
        .foregroundStyle(hub.lampPowerOn ? Color.green : Color.secondary)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("Lamp")
          .font(.system(.title3, design: .rounded).weight(.bold))
        Text(hub.lampPowerOn ? "On" : "Off")
          .font(.system(.subheadline, design: .rounded).weight(.medium))
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Toggle("", isOn: $hub.lampPowerOn)
      .labelsHidden()
      .tint(Color(red: 0.2, green: 0.78, blue: 0.45))
      .scaleEffect(1.35)
      .padding(12)
      .frame(minWidth: 88, minHeight: 52)
      .contentShape(Rectangle())
      .accessibilityLabel("Lamp power")
      .onChange(of: hub.lampPowerOn) { _, _ in
        syncLampImmediate()
      }
    }
    .padding(.vertical, 6)
  }

  private var lampPreviewRow: some View {
    HStack(alignment: .center, spacing: 16) {
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                (Color(hex: previewHex) ?? .pink).opacity(hub.lampPowerOn ? 0.95 : 0.25),
                (Color(hex: previewHex) ?? .purple).opacity(hub.lampPowerOn ? 0.35 : 0.12),
              ],
              center: .center,
              startRadius: 4,
              endRadius: 52
            )
          )
          .frame(width: 88, height: 88)
          .overlay {
            Circle()
              .strokeBorder(.white.opacity(0.35), lineWidth: 2)
          }
          .shadow(color: (Color(hex: previewHex) ?? .clear).opacity(hub.lampPowerOn ? 0.45 : 0.15), radius: hub.blinkEnabled ? 14 : 10, y: 6)

        Image(systemName: hub.blinkEnabled ? "heart.circle.fill" : "sparkles")
          .font(.system(size: 28))
          .foregroundStyle(.white.opacity(0.92))
          .shadow(radius: 2)
          .opacity(hub.lampPowerOn ? 1 : 0.35)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(hub.lastLabel == "—" ? selectedPreset.title : hub.lastLabel)
          .font(.system(.title3, design: .rounded).weight(.bold))
          .foregroundStyle(.primary)
        if !hub.lastUpdatedText.isEmpty {
          Text(hub.lastUpdatedText)
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var moodsAndBlinkSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(moodPresets) { preset in
          moodTile(preset, isSelected: preset.id == selectedMoodId)
        }
      }

      Divider().opacity(0.35)

      HStack(spacing: 8) {
        Image(systemName: "waveform.path.ecg")
          .foregroundStyle(Color.pink.opacity(0.85))
        Text("Blink")
          .font(.system(.headline, design: .rounded).weight(.semibold))
      }

      Toggle(isOn: $hub.blinkEnabled) {
        Text("Blink to BPM")
          .font(.system(.subheadline, design: .rounded).weight(.medium))
      }
      .tint(.pink)
      .onChange(of: hub.blinkEnabled) { _, _ in
        syncLampImmediate()
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Beats per minute")
            .font(.system(.subheadline, design: .rounded))
          Spacer()
          Text("\(Int(hub.blinkBpm.rounded()))")
            .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
            .foregroundStyle(Color.pink.opacity(0.9))
        }

        Slider(value: $hub.blinkBpm, in: 30 ... 220, step: 1)
          .tint(.pink.opacity(0.85))

        TextField("e.g. 72", value: $hub.blinkBpm, format: .number.precision(.fractionLength(0)))
          .keyboardType(.numberPad)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
      }
      .opacity(hub.blinkEnabled ? 1 : 0.45)
      .allowsHitTesting(hub.blinkEnabled)
      .onChange(of: hub.blinkBpm) { _, newVal in
        hub.blinkBpm = min(220, max(30, newVal))
        scheduleLampSyncDebounced()
      }

      if hub.isSending {
        ProgressView()
          .padding(.top, 4)
      }
      if !hub.lastError.isEmpty {
        Text(hub.lastError)
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(.red)
      }
    }
  }

  private var brightnessSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Glow")
          .font(.system(.headline, design: .rounded).weight(.semibold))
        Spacer()
        Text("\(Int(hub.lampBrightness.rounded()))")
          .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
          .foregroundStyle(Color(hex: previewHex)?.opacity(0.95) ?? .primary)
      }
      Slider(value: brightnessSliderBinding, in: 0 ... 255, step: 1)
        .tint(Color(hex: previewHex) ?? .pink)
    }
  }

  private var customColorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: $customColorEnabled) {
        Text("Custom tint")
          .font(.system(.headline, design: .rounded).weight(.semibold))
      }
      .tint(Color(red: 0.98, green: 0.55, blue: 0.72))
      .onChange(of: customColorEnabled) { _, enabled in
        if enabled {
          customColor = Color(hex: selectedPreset.hex) ?? customColor
        }
        syncLampImmediate()
      }

      if customColorEnabled {
        ColorPicker("Tint", selection: $customColor, supportsOpacity: false)
          .labelsHidden()
          .onChange(of: customColor) { _, _ in
            guard customColorEnabled else { return }
            scheduleLampSyncDebounced()
          }
      }
    }
  }

  private var watchAndHealthSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Heart rate", systemImage: "heart.text.square.fill")
        .font(.system(.subheadline, design: .rounded).weight(.bold))
        .foregroundStyle(.secondary)

      HStack {
        Text(hub.authorizationStatus)
        if hub.watchSessionActive {
          Text("Watch")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .font(.system(.caption, design: .rounded))
      .foregroundStyle(.secondary)

      Button("Health access") {
        Task { await hub.authorizeHealthIfNeeded() }
      }
      .font(.system(.subheadline, design: .rounded).weight(.medium))
      .buttonStyle(.bordered)
    }
  }

  private func scheduleLampSyncDebounced() {
    debouncedLampTask?.cancel()
    debouncedLampTask = Task {
      try? await Task.sleep(nanoseconds: lampSyncDebounceNs)
      guard !Task.isCancelled else { return }
      await hub.pushManualLamp(
        mood: selectedMoodId,
        brightness: Int(hub.lampBrightness.rounded()),
        colorHexOverride: customColorEnabled ? customColor.rgbHexString() : nil,
        powerOn: hub.lampPowerOn,
        blinkEnabled: hub.blinkEnabled,
        blinkBpm: hub.blinkBpm
      )
    }
  }

  private func syncLampImmediate() {
    debouncedLampTask?.cancel()
    debouncedLampTask = nil
    Task {
      await hub.pushManualLamp(
        mood: selectedMoodId,
        brightness: Int(hub.lampBrightness.rounded()),
        colorHexOverride: customColorEnabled ? customColor.rgbHexString() : nil,
        powerOn: hub.lampPowerOn,
        blinkEnabled: hub.blinkEnabled,
        blinkBpm: hub.blinkBpm
      )
    }
  }

  @ViewBuilder
  private func moodTile(_ preset: MoodPreset, isSelected: Bool) -> some View {
    Button {
      selectedMoodId = preset.id
      if !customColorEnabled {
        customColor = Color(hex: preset.hex) ?? customColor
      }
      syncLampImmediate()
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: preset.symbol)
            .font(.system(size: 22))
            .foregroundStyle(Color(hex: preset.hex) ?? .pink)
            .shadow(color: (Color(hex: preset.hex) ?? .clear).opacity(0.35), radius: 4, y: 2)
          Spacer()
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 0.98))
              .symbolRenderingMode(.hierarchical)
          }
        }
        Text(preset.title)
          .font(.system(.headline, design: .rounded).weight(.bold))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(
            isSelected
              ? Color(red: 0.92, green: 0.96, blue: 1.0)
              : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.65)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(
            isSelected ? Color(red: 0.55, green: 0.78, blue: 0.98).opacity(0.65) : Color.white.opacity(0.12),
            lineWidth: isSelected ? 2 : 1
          )
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Cute chrome

private struct CuteBackgroundView: View {
  var body: some View {
    LinearGradient(
      colors: [
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

private struct CuteCard<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(.ultraThinMaterial)
          .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
      )
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

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

private enum AppearancePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }
}

struct ContentView: View {
  @EnvironmentObject private var hub: MoodHub
  @Environment(\.colorScheme) private var colorScheme

  /// Overrides system light/dark when not `system` (same idea as day vs night).
  @AppStorage("littleLampAppearance") private var appearanceRaw = AppearancePreference.system.rawValue

  @State private var selectedMoodId = "calm"
  @State private var customColorEnabled = false
  /// 0…1 hue for spectrum tint (saturation/brightness fixed for LED-friendly colors).
  @State private var spectrumHue: Double = 0
  @AppStorage("customMoodDisplayName") private var customMoodName = ""
  @State private var blinkBpmDraft = "72"
  @State private var debouncedLampTask: Task<Void, Never>?

  private var selectedPreset: MoodPreset {
    moodPresets.first { $0.id == selectedMoodId } ?? moodPresets[0]
  }

  private var previewHex: String {
    if customColorEnabled {
      return spectrumHex(fromHue: spectrumHue)
    }
    return selectedPreset.hex
  }

  private var headlineTitle: String {
    if customColorEnabled {
      let t = customMoodName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { return t }
    }
    if hub.lastLabel != "—" {
      return hub.lastLabel
    }
    return selectedPreset.title
  }

  private var spectrumHueBinding: Binding<Double> {
    Binding(
      get: { spectrumHue },
      set: {
        spectrumHue = $0
        scheduleLampSyncDebounced()
      }
    )
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

  private var appearancePreference: Binding<AppearancePreference> {
    Binding(
      get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
      set: { appearanceRaw = $0.rawValue }
    )
  }

  private var resolvedPreferredColorScheme: ColorScheme? {
    switch AppearancePreference(rawValue: appearanceRaw) ?? .system {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        CuteBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
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

            CuteCard {
              appearanceSection
            }
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 28)
        }
      }
      .preferredColorScheme(resolvedPreferredColorScheme)
      .navigationTitle("Little Lamp ✨")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            hub.lampPowerOn.toggle()
            syncLampImmediate()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: hub.lampPowerOn ? "power.circle.fill" : "power.circle")
                .font(.system(size: 20))
              Text(hub.lampPowerOn ? "On" : "Off")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
            }
            .foregroundStyle(hub.lampPowerOn ? Color.green : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
              Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
              Capsule(style: .continuous)
                .strokeBorder(hub.lampPowerOn ? Color.green.opacity(0.45) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Capsule(style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Lamp power")
          .accessibilityValue(hub.lampPowerOn ? "On" : "Off")
        }
      }
    }
    .task {
      await hub.authorizeHealthIfNeeded()
    }
    .onAppear {
      if validMoods.contains(hub.lastMood) {
        selectedMoodId = hub.lastMood
      }
      if customColorEnabled {
        spectrumHue = hueFromPresetHex(selectedPreset.hex)
      }
      blinkBpmDraft = String(Int(hub.blinkBpm.rounded()))
    }
    .task(id: selectedMoodId) {
      await hub.refreshMoodInsight(selectedFallbackMood: selectedMoodId)
    }
    .onChange(of: hub.blinkBpm) { _, newVal in
      blinkBpmDraft = String(Int(newVal.rounded()))
    }
    .onDisappear {
      debouncedLampTask?.cancel()
      debouncedLampTask = nil
    }
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
        Text(headlineTitle)
          .font(.system(.title3, design: .rounded).weight(.bold))
          .foregroundStyle(.primary)
        if !hub.moodInsight.isEmpty {
          Text(hub.moodInsight)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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

      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "waveform.path.ecg")
          .font(.system(size: 22))
          .foregroundStyle(Color.pink.opacity(0.85))
          .frame(width: 28, alignment: .center)
        Text("Blink")
          .font(.system(.headline, design: .rounded).weight(.semibold))
        Spacer(minLength: 8)
        Toggle("Blink to BPM", isOn: $hub.blinkEnabled)
          .labelsHidden()
          .tint(.pink)
          .accessibilityLabel("Blink to BPM")
      }
      .frame(minHeight: 44)
      .onChange(of: hub.blinkEnabled) { _, _ in
        syncLampImmediate()
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Heartbeat (BPM)")
            .font(.system(.subheadline, design: .rounded))
          Spacer()
          Text("Now \(Int(hub.blinkBpm.rounded()))")
            .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.pink.opacity(0.9))
        }

        TextField("e.g. 72", text: $blinkBpmDraft)
          .keyboardType(.numberPad)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
          .disabled(!hub.blinkEnabled)

        Button {
          applyHeartbeatBpmEntry()
        } label: {
          Text("Apply heartbeat")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pink)
        .disabled(!hub.blinkEnabled)

        Text("Uses 30–220 BPM on the lamp (values are adjusted when you apply).")
          .font(.system(.caption2, design: .rounded))
          .foregroundStyle(.secondary)
      }
      .opacity(hub.blinkEnabled ? 1 : 0.45)
      .allowsHitTesting(hub.blinkEnabled)

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
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 10) {
        Text("Custom tint")
          .font(.system(.headline, design: .rounded).weight(.semibold))
        Spacer(minLength: 8)
        Toggle("Custom tint", isOn: $customColorEnabled)
          .labelsHidden()
          .tint(Color(red: 0.98, green: 0.55, blue: 0.72))
          .accessibilityLabel("Custom tint")
      }
      .frame(minHeight: 44)
      .onChange(of: customColorEnabled) { _, enabled in
        if enabled {
          spectrumHue = hueFromPresetHex(selectedPreset.hex)
        }
        syncLampImmediate()
      }

      if customColorEnabled {
        Text("Spectrum")
          .font(.system(.subheadline, design: .rounded).weight(.semibold))
          .foregroundStyle(.secondary)

        ZStack {
          LinearGradient(
            colors: [
              .red,
              Color(red: 1, green: 1, blue: 0),
              .green,
              .cyan,
              .blue,
              Color(red: 0.58, green: 0.44, blue: 0.86),
              .red,
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(height: 36)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          Slider(value: spectrumHueBinding, in: 0 ... 1)
            .tint(Color.white.opacity(0.35))
            .padding(.horizontal, 4)
        }

        TextField("Name this mood", text: $customMoodName)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .rounded))
          .onChange(of: customMoodName) { _, newVal in
            if newVal.count > 48 {
              customMoodName = String(newVal.prefix(48))
            }
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

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: Binding(
        get: {
          AppearancePreference(rawValue: appearanceRaw) != .system
        },
        set: { fixed in
          if fixed {
            appearanceRaw = (colorScheme == .dark ? AppearancePreference.dark : AppearancePreference.light).rawValue
          } else {
            appearanceRaw = AppearancePreference.system.rawValue
          }
        }
      )) {
        Text("Fixed day/night look")
          .font(.system(.subheadline, design: .rounded).weight(.semibold))
      }
      .tint(.indigo)

      if AppearancePreference(rawValue: appearanceRaw) != .system {
        Picker("Interface", selection: appearancePreference) {
          Text("Light").tag(AppearancePreference.light)
          Text("Dark").tag(AppearancePreference.dark)
        }
        .pickerStyle(.segmented)
      }
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
        colorHexOverride: colorHexForAPI(),
        powerOn: hub.lampPowerOn,
        blinkEnabled: hub.blinkEnabled,
        blinkBpm: hub.blinkBpm,
        moodLabel: resolvedMoodLabelForAPI()
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
        colorHexOverride: colorHexForAPI(),
        powerOn: hub.lampPowerOn,
        blinkEnabled: hub.blinkEnabled,
        blinkBpm: hub.blinkBpm,
        moodLabel: resolvedMoodLabelForAPI()
      )
    }
  }

  @ViewBuilder
  private func moodTile(_ preset: MoodPreset, isSelected: Bool) -> some View {
    Button {
      hub.clearInsightHeartContextForManualSelection()
      selectedMoodId = preset.id
      if customColorEnabled {
        spectrumHue = hueFromPresetHex(preset.hex)
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

  private func applyHeartbeatBpmEntry() {
    hub.lastError = ""
    let trimmed = blinkBpmDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      blinkBpmDraft = String(Int(hub.blinkBpm.rounded()))
      return
    }
    let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
    guard let parsed = Double(normalized), parsed.isFinite else {
      hub.lastError = "Enter a valid number for BPM."
      return
    }
    let clamped = min(220, max(30, parsed))
    hub.blinkBpm = clamped
    blinkBpmDraft = String(Int(clamped.rounded()))
    syncLampImmediate()
  }

  private func resolvedMoodLabelForAPI() -> String? {
    guard customColorEnabled else { return nil }
    let t = customMoodName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    return String(t.prefix(48))
  }

  private func colorHexForAPI() -> String? {
    guard customColorEnabled else { return nil }
    return spectrumHex(fromHue: spectrumHue)
  }

  private func hueFromPresetHex(_ hex: String) -> Double {
    guard let swift = Color(hex: hex) else { return 0 }
    let ui = UIColor(swift)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return 0 }
    return Double(h)
  }

  private func spectrumHex(fromHue hue: Double) -> String {
    let ui = UIColor(hue: CGFloat(hue), saturation: 0.92, brightness: 0.98, alpha: 1)
    var r: CGFloat = 0
    var g: CGFloat = 0
    var bl: CGFloat = 0
    var a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &bl, alpha: &a)
    return String(
      format: "#%02X%02X%02X",
      Int(round(r * 255)),
      Int(round(g * 255)),
      Int(round(bl * 255))
    )
  }
}

// MARK: - Cute chrome

private struct CuteBackgroundView: View {
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

private struct CuteCard<Content: View>: View {
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

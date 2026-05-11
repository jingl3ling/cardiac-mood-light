import SwiftUI

struct ViewerRootView: View {
  @EnvironmentObject private var model: ViewerViewModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var colorScheme

  @State private var brightnessDraft: Double = 120
  @State private var brightnessPushTask: Task<Void, Never>?

  private let accentPink = Color.pink.opacity(0.88)

  var body: some View {
    NavigationStack {
      ZStack {
        ViewerBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ViewerGlassCard {
              heroCardContent
                .padding(.top, 4)
            }

            ViewerGlassCard {
              viewerFamilyInsightSection
            }

            ViewerGlassCard {
              heartRateSection
            }

            ViewerGlassCard {
              controlsSection
            }

            if !model.statusMessage.isEmpty {
              statusBanner
                .padding(.horizontal, 2)
            }
          }
          .padding(.horizontal, 18)
          .padding(.top, 14)
          .padding(.bottom, 28)
        }
        .refreshable {
          await model.refresh()
        }
      }
      .navigationTitle("Little Lamp · Family ✨")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
    }
    .onAppear {
      if let b = model.lampState?.brightness {
        brightnessDraft = Double(b)
      }
      model.startPolling()
      Task { await model.refresh() }
    }
    .onDisappear {
      model.stopPolling()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await model.pollMainAppTriggeredRefreshIfNeeded() }
      }
    }
    .onChange(of: model.lampState?.brightness) { _, newVal in
      if let newVal {
        brightnessDraft = Double(newVal)
      }
    }
  }

  // MARK: - Hero

  private var lampHex: String {
    model.lampState?.color ?? "#FFB3D9"
  }

  private var powerOn: Bool {
    model.lampState?.powerOn ?? true
  }

  private var blinkEnabled: Bool {
    model.lampState?.blinkEnabled ?? false
  }

  private var heroCardContent: some View {
    HStack(alignment: .center, spacing: 18) {
      FamilyLampGlowOrb(
        colorHex: lampHex,
        powerOn: powerOn,
        blinkEnabled: blinkEnabled
      )

      VStack(alignment: .leading, spacing: 8) {
        Text(moodTitle)
          .font(.system(.title3, design: .rounded).weight(.bold))
          .foregroundStyle(.primary)

        if let moodSubtitle {
          Text(moodSubtitle)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(powerOn ? "Lamp is on" : "Lamp is off · waiting to glow again")
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
  }

  private var moodTitle: String {
    let m = (model.lampState?.mood ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !m.isEmpty { return m.capitalized }
    return "Waiting…"
  }

  private var moodSubtitle: String? {
    guard let raw = model.lampState?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let moodLower = (model.lampState?.mood ?? "").lowercased()
    if raw.lowercased() == moodLower { return nil }
    return raw
  }

  // MARK: - Sections

  private func sectionHeader(icon: String, iconTint: Color, title: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 22))
        .foregroundStyle(iconTint)
        .frame(width: 28, alignment: .center)
      Text(title)
        .font(.system(.headline, design: .rounded).weight(.semibold))
    }
    .frame(minHeight: 44)
    .padding(.bottom, 2)
  }

  private var viewerFamilyInsightSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader(icon: "sparkles", iconTint: Color.purple.opacity(0.82), title: "Family insight")

      if model.viewerFamilyCaptionLoading, model.viewerFamilyCaption.isEmpty {
        ProgressView()
          .padding(.vertical, 4)
      }

      if model.viewerFamilyCaptionError.isEmpty == false, model.viewerFamilyCaption.isEmpty {
        Text(model.viewerFamilyCaptionError)
          .font(.system(.caption, design: .rounded).weight(.medium))
          .foregroundStyle(Color.red.opacity(0.92))
          .fixedSize(horizontal: false, vertical: true)
      }

      if !model.viewerFamilyCaption.isEmpty {
        Text(model.viewerFamilyCaption)
          .font(.system(.body, design: .rounded))
          .foregroundStyle(.primary)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      } else if !model.viewerFamilyCaptionLoading {
        Text("Waiting for lamp data…")
          .font(.system(.body, design: .rounded))
          .foregroundStyle(.secondary)
      }
    }
  }

  /// When blink is on, lamp `blinkBpm` tracks Health on the primary phone (`/sync-blink`).
  private var heartbeatBpmForDisplay: Double? {
    guard let s = model.lampState else { return nil }
    if (s.blinkEnabled == true), let blink = s.blinkBpm {
      return blink
    }
    return s.reportedHeartRateBpm ?? s.blinkBpm
  }

  /// Same idea as Cardiac Mood’s `appleHealthHeartRateDetail` (“Updated 3:42 PM”) — server stamps `reportedHeartRateAt` on viewer-context and sync-blink.
  private var heartbeatUpdatedDetail: String? {
    guard let at = model.lampState?.reportedHeartRateAt, at > 0 else { return nil }
    let d = Date(timeIntervalSince1970: at)
    let t = DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
    return "Updated \(t)"
  }

  private var heartRateSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionHeader(icon: "heart.circle.fill", iconTint: accentPink, title: "Latest heartbeat")

      if let bpm = heartbeatBpmForDisplay {
        HStack(alignment: .firstTextBaseline) {
          Text("\(Int(bpm.rounded())) BPM")
            .font(.system(.title2, design: .rounded).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.primary)

          Spacer(minLength: 8)

          if let tsLine = heartbeatUpdatedDetail {
            Text(tsLine)
              .font(.system(.caption, design: .rounded))
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          }
        }

        Text("From Little Lamp when it syncs heart rate or pulse blink.")
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(.tertiary)
      } else {
        Text("Waiting for a sync from Little Lamp…")
          .font(.system(.subheadline, design: .rounded))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var controlsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(icon: "slider.horizontal.3", iconTint: Color.orange.opacity(0.82), title: "Controls")

      Toggle(
        isOn: Binding(
          get: { model.lampState?.powerOn ?? true },
          set: { v in Task { await applyLamp(brightness: Int(brightnessDraft.rounded()), powerOn: v) } }
        )
      ) {
        Text("Lamp on")
          .font(.system(.body, design: .rounded))
      }
      .tint(.pink)
      .disabled(model.lampState == nil)

      Divider().opacity(0.35)

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Brightness")
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
          Spacer()
          Text("\(Int(brightnessDraft.rounded()))")
            .font(.system(.title3, design: .rounded).weight(.bold))
            .monospacedDigit()
        }
        Slider(value: $brightnessDraft, in: 0 ... 255, step: 1)
          .disabled(model.lampState == nil)
          .tint(.pink.opacity(0.85))
          .onChange(of: brightnessDraft) { _, _ in
            scheduleBrightnessPush()
          }
      }

      Divider().opacity(0.35)

      HStack {
        Image(systemName: "waveform.path.ecg")
          .font(.system(size: 20))
          .foregroundStyle(accentPink)
          .frame(width: 28)
        Toggle(
          isOn: Binding(
            get: { model.lampState?.blinkEnabled ?? false },
            set: { v in
              Task {
                let bpm = model.lampState?.blinkBpm ?? 72
                await model.syncBlinkOnly(blinkBpm: bpm, blinkEnabled: v)
              }
            }
          )
        ) {
          Text("Blink to pulse")
            .font(.system(.body, design: .rounded))
        }
        .tint(.pink)
      }
      .disabled(model.lampState == nil)
    }
  }

  private var statusBanner: some View {
    Text(model.statusMessage)
      .font(.system(.caption, design: .rounded).weight(.medium))
      .foregroundStyle(Color.red.opacity(0.92))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 11)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color.red.opacity(colorScheme == .dark ? 0.14 : 0.09))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
          )
      )
  }

  // MARK: - Actions

  private func scheduleBrightnessPush() {
    brightnessPushTask?.cancel()
    brightnessPushTask = Task {
      try? await Task.sleep(nanoseconds: 450_000_000)
      guard !Task.isCancelled else { return }
      await applyLamp(brightness: Int(brightnessDraft.rounded()), powerOn: model.lampState?.powerOn ?? true)
    }
  }

  private func applyLamp(brightness: Int, powerOn: Bool) async {
    guard let s = model.lampState else { return }
    await model.applyManual(
      brightness: brightness,
      powerOn: powerOn,
      blinkEnabled: s.blinkEnabled ?? false,
      blinkBpm: s.blinkBpm ?? 72
    )
  }
}

#Preview {
  ViewerRootView()
    .environmentObject(ViewerViewModel())
}

import SwiftUI

struct ViewerRootView: View {
  @EnvironmentObject private var model: ViewerViewModel
  @State private var brightnessDraft: Double = 120
  @State private var brightnessPushTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          moodHeader
          insightBlock
          heartRateBlock
          Divider()
          controlsBlock
          if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        .padding(20)
      }
      .navigationTitle("Little Lamp — Family")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await model.refresh() }
          } label: {
            Image(systemName: "arrow.clockwise.circle.fill")
          }
        }
      }
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
    .onChange(of: model.lampState?.brightness) { _, newVal in
      if let newVal {
        brightnessDraft = Double(newVal)
      }
    }
  }

  private var insightText: String {
    let s = model.lampState?.moodInsight?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if s.isEmpty {
      return
        "No mood line yet. On their phone, Little Lamp adds a sentence after heart-rate analyze or the Explain mood action; it usually appears here within a few seconds."
    }
    return s
  }

  /// Palette word from the server (`mood`) — not the preset marketing `label`, which can disagree with the lamp color.
  private var moodTitle: String {
    let m = (model.lampState?.mood ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !m.isEmpty { return m.capitalized }
    return "…"
  }

  /// Optional preset title when it differs from the base mood (e.g. custom copy vs `calm`).
  private var moodSubtitle: String? {
    guard let raw = model.lampState?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let moodLower = (model.lampState?.mood ?? "").lowercased()
    if raw.lowercased() == moodLower { return nil }
    return raw
  }

  private var moodHeader: some View {
    HStack(alignment: .top, spacing: 16) {
      Circle()
        .fill((Color(hex: model.lampState?.color ?? "#888888") ?? .gray).opacity(model.lampState?.powerOn == false ? 0.25 : 1))
        .frame(width: 64, height: 64)
        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 2))
      VStack(alignment: .leading, spacing: 6) {
        Text(moodTitle)
          .font(.title2.weight(.bold))
        if let moodSubtitle {
          Text(moodSubtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var insightBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Mood note", systemImage: "text.quote")
        .font(.headline)
      Text(insightText)
        .font(.body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// When blink is on, lamp `blinkBpm` tracks Health on the primary phone (`/sync-blink`); stale `reportedHeartRate*` can linger from older `/viewer-context` posts.
  private var heartbeatBpmForDisplay: Double? {
    guard let s = model.lampState else { return nil }
    if (s.blinkEnabled == true), let blink = s.blinkBpm {
      return blink
    }
    return s.reportedHeartRateBpm ?? s.blinkBpm
  }

  private var heartbeatRelativeUpdateText: String {
    guard let s = model.lampState else { return "" }
    let epoch: Double? = {
      if s.blinkEnabled == true {
        return s.updatedAt ?? s.reportedHeartRateAt
      }
      return s.reportedHeartRateAt ?? s.updatedAt
    }()
    guard let epoch else { return "" }
    let d = Date(timeIntervalSince1970: epoch)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return "Updated \(f.localizedString(for: d, relativeTo: Date()))"
  }

  private var heartRateBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Latest heartbeat (from their phone)", systemImage: "heart.fill")
        .font(.headline)
        .foregroundStyle(.pink)
      if let bpm = heartbeatBpmForDisplay {
        HStack(alignment: .firstTextBaseline) {
          Text("\(Int(bpm.rounded()))")
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("BPM")
            .font(.title3.weight(.semibold))
        }
        Text(heartbeatRelativeUpdateText)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Waiting for a heart-rate sync from the main app…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var controlsBlock: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Controls")
        .font(.headline)
      Toggle(
        "Lamp on",
        isOn: Binding(
          get: { model.lampState?.powerOn ?? true },
          set: { v in Task { await applyLamp(brightness: Int(brightnessDraft.rounded()), powerOn: v) } }
        )
      )
      .disabled(model.lampState == nil)

      VStack(alignment: .leading) {
        HStack {
          Text("Brightness")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(Int(brightnessDraft.rounded()))")
            .font(.title3.weight(.bold).monospacedDigit())
        }
        Slider(value: $brightnessDraft, in: 0 ... 255, step: 1)
          .disabled(model.lampState == nil)
          .onChange(of: brightnessDraft) { _, _ in
            scheduleBrightnessPush()
          }
      }

      Toggle(
        "Blink to pulse",
        isOn: Binding(
          get: { model.lampState?.blinkEnabled ?? false },
          set: { v in
            Task {
              let bpm = model.lampState?.blinkBpm ?? 72
              await model.syncBlinkOnly(blinkBpm: bpm, blinkEnabled: v)
            }
          }
        )
      )
      .disabled(model.lampState == nil)

      if let bpm = model.lampState?.blinkBpm {
        HStack {
          Text("Blink speed (BPM)")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("\(Int(bpm.rounded()))")
            .font(.body.monospacedDigit())
        }
      }
    }
  }

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

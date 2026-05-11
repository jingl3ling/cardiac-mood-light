import Foundation
import SwiftUI

@MainActor
final class ViewerViewModel: ObservableObject {
  @Published var lampState: LatestStateDTO?
  @Published var statusMessage = ""

  /// Separate Claude caption for whoever is checking MoodViewer — distinct prompt from `/explain-mood` on Little Lamp.
  @Published private(set) var viewerFamilyCaption = ""
  @Published private(set) var viewerFamilyCaptionLoading = false
  /// Set when Claude/network fails while caption is empty.
  @Published var viewerFamilyCaptionError = ""

  private let api = CardiacAPIClient()
  private var pollTask: Task<Void, Never>?
  private var viewerCaptionScheduleTask: Task<Void, Never>?

  /// Little Lamp timestamps server mutations via `FamilySyncBeacon`; we skip redundant GET work until something newer arrives.
  private var handledBeaconThrough: TimeInterval = 0

  /// Watch app-group pings at ~1 Hz (cheap reads); unconditional `/latest` less often so radio stays asleep when nothing changed.
  private let fastWakeCheckSeconds: Double = 1
  /// Every N fast ticks, GET `/latest` anyway — needed when Little Lamp runs on another device (App Group beacon is same-phone only).
  private let unconditionalRefreshEveryTicks = 6

  private var viewerCaptionGeneration = 0
  private var viewerInsightFetchedForKey: String?

  private static let viewerMoods: Set<String> = ["calm", "stressed", "happy", "sad"]

  func startPolling() {
    pollTask?.cancel()
    pollTask = Task {
      var tick = 0
      while !Task.isCancelled {
        await pollMainAppTriggeredRefreshIfNeeded()
        tick += 1
        if tick >= unconditionalRefreshEveryTicks {
          tick = 0
          await refresh()
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0.35, fastWakeCheckSeconds) * 1_000_000_000))
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    viewerCaptionScheduleTask?.cancel()
    viewerCaptionScheduleTask = nil
  }

  /// Immediate check when MoodViewer foregrounds — Little Lamp bumps a shared beacon on each successful API write.
  func pollMainAppTriggeredRefreshIfNeeded() async {
    let stamp = FamilySyncBeacon.lastMainAppServerMutationAt()
    /// Require `stamp > handledBeaconThrough` so the "never wrote beacon" pair (both 0) does not wrongly skip cross-device polls.
    if stamp <= handledBeaconThrough {
      return
    }
    await refresh()
  }

  func refresh() async {
    do {
      let s = try await api.getLatest(deviceId: Config.deviceId)
      lampState = s
      statusMessage = ""
      handledBeaconThrough = max(handledBeaconThrough, FamilySyncBeacon.lastMainAppServerMutationAt())
      if viewerFamilyCaptionContextKey() != viewerInsightFetchedForKey {
        viewerFamilyCaption = ""
        viewerFamilyCaptionError = ""
      }
      scheduleViewerFamilyCaptionGeneration()
    } catch {
      statusMessage = "Could not load lamp state. Check network and API key."
      lampState = nil
      viewerFamilyCaption = ""
      viewerInsightFetchedForKey = nil
      viewerFamilyCaptionLoading = false
    }
  }

  func applyManual(
    brightness: Int,
    powerOn: Bool,
    blinkEnabled: Bool,
    blinkBpm: Double
  ) async {
    guard let s = lampState else {
      await refresh()
      return
    }
    do {
      let resp = try await api.manualLamp(
        deviceId: Config.deviceId,
        mood: s.mood,
        brightness: min(255, max(0, brightness)),
        colorHex: nil,
        powerOn: powerOn,
        blinkEnabled: blinkEnabled,
        blinkBpm: blinkBpm,
        moodLabel: nil
      )
      lampState = LatestStateDTO(
        mood: resp.mood,
        label: resp.label,
        color: resp.color,
        brightness: resp.brightness,
        updatedAt: resp.updatedAt,
        powerOn: resp.powerOn,
        blinkEnabled: resp.blinkEnabled,
        blinkBpm: resp.blinkBpm,
        reportedHeartRateBpm: lampState?.reportedHeartRateBpm,
        reportedHeartRateAt: lampState?.reportedHeartRateAt,
        moodInsight: lampState?.moodInsight,
        viewerContextUpdatedAt: lampState?.viewerContextUpdatedAt
      )
      statusMessage = ""
      scheduleViewerFamilyCaptionGeneration()
    } catch {
      statusMessage = "Update failed. Try again."
    }
  }

  func syncBlinkOnly(blinkBpm: Double, blinkEnabled: Bool) async {
    do {
      let resp = try await api.syncBlink(
        deviceId: Config.deviceId,
        blinkBpm: blinkBpm,
        blinkEnabled: blinkEnabled
      )
      lampState = LatestStateDTO(
        mood: resp.mood,
        label: resp.label,
        color: resp.color,
        brightness: resp.brightness,
        updatedAt: resp.updatedAt,
        powerOn: resp.powerOn,
        blinkEnabled: resp.blinkEnabled,
        blinkBpm: resp.blinkBpm,
        reportedHeartRateBpm: lampState?.reportedHeartRateBpm,
        reportedHeartRateAt: lampState?.reportedHeartRateAt,
        moodInsight: lampState?.moodInsight,
        viewerContextUpdatedAt: lampState?.viewerContextUpdatedAt
      )
      statusMessage = ""
      scheduleViewerFamilyCaptionGeneration()
    } catch {
      statusMessage = "Blink update failed."
    }
  }

  private func scheduleViewerFamilyCaptionGeneration() {
    viewerCaptionScheduleTask?.cancel()
    viewerCaptionScheduleTask = Task {
      try? await Task.sleep(nanoseconds: 450_000_000)
      await generateViewerFamilyCaptionIfNeeded()
    }
  }

  private static func viewerLocalCalendarDateString() -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
  }

  /// Mirrors `heartbeatBpmForDisplay` in `ViewerRootView` for explain payload BPM.
  private static func heartbeatBpmForExplain(_ s: LatestStateDTO?) -> Double? {
    guard let s else { return nil }
    if (s.blinkEnabled == true), let blink = s.blinkBpm {
      return blink
    }
    return s.reportedHeartRateBpm ?? s.blinkBpm
  }

  private func viewerFamilyCaptionContextKey() -> String? {
    guard let s = lampState else { return nil }
    let mood = s.mood.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.viewerMoods.contains(mood) else { return nil }

    let bpmPart: String = {
      guard let v = Self.heartbeatBpmForExplain(s), v.isFinite else { return "_" }
      return "\(Int(v.rounded()))"
    }()
    let li = (s.moodInsight ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let liKey = String(li.prefix(120))
    return "\(mood)|\(bpmPart)|\(liKey)"
  }

  private func customMoodLabelForExplain(_ s: LatestStateDTO) -> String? {
    guard let raw = s.label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let moodLower = s.mood.lowercased()
    if raw.lowercased() == moodLower { return nil }
    return String(raw.prefix(48))
  }

  private func generateViewerFamilyCaptionIfNeeded() async {
    guard let key = viewerFamilyCaptionContextKey() else {
      viewerFamilyCaption = ""
      viewerInsightFetchedForKey = nil
      viewerFamilyCaptionError = ""
      return
    }
    if key == viewerInsightFetchedForKey, !viewerFamilyCaption.isEmpty {
      return
    }

    viewerCaptionGeneration += 1
    let token = viewerCaptionGeneration
    viewerFamilyCaptionLoading = true
    viewerFamilyCaptionError = ""
    defer {
      if token == viewerCaptionGeneration {
        viewerFamilyCaptionLoading = false
      }
    }

    guard let s = lampState else { return }
    let mood = s.mood.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.viewerMoods.contains(mood) else {
      viewerFamilyCaption = ""
      viewerFamilyCaptionError = ""
      return
    }

    var recent: [Double]?
    if let bpm = Self.heartbeatBpmForExplain(s), bpm.isFinite {
      recent = [min(230, max(30, bpm))]
    }

    let lampInsight: String? = {
      let t = (s.moodInsight ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : String(t.prefix(400))
    }()

    do {
      let caption = try await api.explainMoodInsightViewer(
        deviceId: Config.deviceId,
        mood: mood,
        localDate: Self.viewerLocalCalendarDateString(),
        timeZoneId: TimeZone.current.identifier,
        restingBpm: nil,
        recentBpms: recent,
        classifierReason: nil,
        analyzeSource: "mood_viewer",
        customMoodName: customMoodLabelForExplain(s),
        lampMoodInsight: lampInsight
      )
      guard token == viewerCaptionGeneration else { return }
      viewerFamilyCaption = caption
      viewerInsightFetchedForKey = key
    } catch {
      guard token == viewerCaptionGeneration else { return }
      if viewerFamilyCaption.isEmpty {
        viewerFamilyCaptionError = "Could not load family insight."
      }
    }
  }
}

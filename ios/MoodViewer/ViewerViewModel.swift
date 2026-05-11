import CoreFoundation
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

  /// Retains the Darwin notify observer for the app lifetime.
  private var familyLampDarwinBox: MoodViewerFamilyDarwinBox?

  /// Little Lamp timestamps server mutations via `FamilySyncBeacon`; we skip redundant GET work until something newer arrives.
  private var handledBeaconThrough: TimeInterval = 0

  /// Watch app-group pings at ~1 Hz (cheap reads); unconditional `/latest` less often so radio stays asleep when nothing changed.
  private let fastWakeCheckSeconds: Double = 1
  /// Every N fast ticks, GET `/latest` anyway — needed when Little Lamp runs on another device (App Group beacon is same-phone only).
  private let unconditionalRefreshEveryTicks = 10

  private var viewerCaptionGeneration = 0
  private var viewerInsightFetchedForKey: String?
  /// Mood used for the last successful family insight response; suppresses duplicate `/explain-mood-viewer` while mood is stable.
  private var lastFetchedFamilyInsightMoodLower: String?
  /// True after `refresh(forceFamilyInsightRegeneration:)` (e.g. pull-to-refresh); bypasses mood-only cache for one generation pass.
  private var pendingForceFamilyInsightRegeneration = false

  private static let viewerMoods: Set<String> = ["calm", "stressed", "happy", "sad"]

  private static func normalizedMood(_ s: LatestStateDTO?) -> String? {
    guard let raw = s?.mood.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty, viewerMoods.contains(raw)
    else { return nil }
    return raw
  }

  func startPolling() {
    if familyLampDarwinBox == nil {
      let box = MoodViewerFamilyDarwinBox { [weak self] in
        Task { @MainActor in await self?.refresh(forceFamilyInsightRegeneration: false) }
      }
      familyLampDarwinBox = box
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(box).toOpaque(),
        moodViewerFamilyLampDarwinCallback,
        FamilySyncBeacon.lampMutationDarwinName as CFString,
        nil,
        CFNotificationSuspensionBehavior.deliverImmediately
      )
    }

    pollTask?.cancel()
    pollTask = Task {
      var tick = 0
      while !Task.isCancelled {
        await pollMainAppTriggeredRefreshIfNeeded()
        tick += 1
        if tick >= unconditionalRefreshEveryTicks {
          tick = 0
          await refresh(forceFamilyInsightRegeneration: false)
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

  /// Immediate check when MoodViewer foregrounds — Little Lamp bumps Darwin notify + optional app-group timestamp.
  func pollMainAppTriggeredRefreshIfNeeded() async {
    let stamp = FamilySyncBeacon.lastMainAppServerMutationAt()
    /// Require `stamp > handledBeaconThrough` so the (0,0) “no app group” pair does not suppress cross-device polls.
    if stamp <= handledBeaconThrough {
      return
    }
    await refresh(forceFamilyInsightRegeneration: false)
  }

  func refresh(forceFamilyInsightRegeneration: Bool = false) async {
    if forceFamilyInsightRegeneration {
      pendingForceFamilyInsightRegeneration = true
      viewerFamilyCaptionError = ""
      lastFetchedFamilyInsightMoodLower = nil
      viewerInsightFetchedForKey = nil
    }

    let moodBeforeFetch = Self.normalizedMood(lampState)

    do {
      let s = try await api.getLatest(deviceId: Config.deviceId)
      let moodAfterFetch = Self.normalizedMood(s)

      lampState = s
      statusMessage = ""
      handledBeaconThrough = max(handledBeaconThrough, FamilySyncBeacon.lastMainAppServerMutationAt())

      let moodChanged = moodBeforeFetch != moodAfterFetch

      let keyNow = viewerFamilyCaptionContextKey()
      if let keyNow, keyNow != viewerInsightFetchedForKey {
        viewerFamilyCaption = ""
        viewerFamilyCaptionError = ""
      }

      scheduleViewerFamilyInsightIfAppropriate(
        moodChanged: moodChanged,
        newKeyIfAny: viewerFamilyCaptionContextKey(),
        lampMoodNormalized: moodAfterFetch
      )
    } catch {
      statusMessage = "Could not load lamp state. Check network and API key."
      lampState = nil
      viewerFamilyCaption = ""
      viewerInsightFetchedForKey = nil
      lastFetchedFamilyInsightMoodLower = nil
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
        viewerContextUpdatedAt: lampState?.viewerContextUpdatedAt,
        healthHeartRateUiDetail: lampState?.healthHeartRateUiDetail,
        appleHealthHeartRateSampleEndAt: lampState?.appleHealthHeartRateSampleEndAt
      )
      statusMessage = ""
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
        viewerContextUpdatedAt: lampState?.viewerContextUpdatedAt,
        healthHeartRateUiDetail: lampState?.healthHeartRateUiDetail,
        appleHealthHeartRateSampleEndAt: lampState?.appleHealthHeartRateSampleEndAt
      )
      statusMessage = ""
    } catch {
      statusMessage = "Blink update failed."
    }
  }

  /// Debounced `/explain-mood-viewer` — scheduling is skipped when mood is unchanged and caption already populated (poll stays cheap).
  private func scheduleViewerFamilyInsightIfAppropriate(
    moodChanged: Bool,
    newKeyIfAny: String?,
    lampMoodNormalized: String?
  ) {
    let force = pendingForceFamilyInsightRegeneration
    /// First successful insight load (`viewerInsightFetchedForKey` stays nil until a network caption lands).
    let awaitingFirstSuccess =
      viewerFamilyCaption.isEmpty && viewerFamilyCaptionError.isEmpty
      && viewerInsightFetchedForKey == nil

    guard force || moodChanged || awaitingFirstSuccess else {
      return
    }
    guard !viewerFamilyCaptionLoading else {
      /// Avoid canceling an in-flight debounce + request while Claude is already working or debouncing.
      return
    }
    guard lampMoodNormalized != nil, newKeyIfAny != nil else {
      return
    }

    scheduleViewerFamilyCaptionGeneration()
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

  /// Matches server `STYLE` preset labels — must not be sent as `customMoodName` or stale calm copy overrides stressed/happy moods in family insight.
  private static let stockLampPresetLabelsLower: Set<String> = [
    "calm (baseline)",
    "escalating / stressed",
    "happy / energetic",
    "sad / drained",
  ]

  private func customMoodLabelForExplain(_ s: LatestStateDTO) -> String? {
    guard let raw = s.label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let moodLower = s.mood.lowercased()
    if raw.lowercased() == moodLower { return nil }
    let low = raw.lowercased()
    if Self.stockLampPresetLabelsLower.contains(low) {
      return nil
    }
    return String(raw.prefix(48))
  }

  private func generateViewerFamilyCaptionIfNeeded() async {
    guard let key = viewerFamilyCaptionContextKey() else {
      viewerFamilyCaption = ""
      viewerInsightFetchedForKey = nil
      viewerFamilyCaptionError = ""
      return
    }

    let forceRegen = pendingForceFamilyInsightRegeneration
    /// Pull-to-refresh must bypass caches even when BPM / sync note fingerprint matches.
    if key == viewerInsightFetchedForKey, !viewerFamilyCaption.isEmpty, !forceRegen {
      return
    }

    let moodNow = lampState.flatMap { Self.normalizedMood($0) } ?? ""
    if !forceRegen,
      let lastInsightMood = lastFetchedFamilyInsightMoodLower,
      lastInsightMood == moodNow,
      !viewerFamilyCaption.isEmpty,
      viewerFamilyCaptionError.isEmpty
    {
      return
    }

    pendingForceFamilyInsightRegeneration = false
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
      lastFetchedFamilyInsightMoodLower = mood
    } catch {
      guard token == viewerCaptionGeneration else { return }
      if viewerFamilyCaption.isEmpty {
        viewerFamilyCaptionError = "Could not load family insight."
      }
    }
  }
}

// MARK: - Darwin notify (Little Lamp → MoodViewer, same device)

private final class MoodViewerFamilyDarwinBox {
  let onFire: () -> Void
  init(onFire: @escaping () -> Void) {
    self.onFire = onFire
  }

  func fire() {
    DispatchQueue.main.async { self.onFire() }
  }
}

private func moodViewerFamilyLampDarwinCallback(
  _: CFNotificationCenter?,
  observer: UnsafeMutableRawPointer?,
  _: CFNotificationName?,
  _: UnsafeRawPointer?,
  _: CFDictionary?
) {
  guard let observer else { return }
  Unmanaged<MoodViewerFamilyDarwinBox>.fromOpaque(observer).takeUnretainedValue().fire()
}

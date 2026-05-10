import Combine
import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity

@MainActor
final class MoodHub: NSObject, ObservableObject {
  @Published var authorizationStatus = "Tap to authorize Health"
  @Published var lastMood = "—"
  @Published var lastLabel = "—"
  @Published var lastColorHex = "#808080"
  @Published var lastReason = ""
  /// Friendly sentence from `/v1/cardiac/explain-mood` (Claude or server fallback).
  @Published var moodInsight = ""
  @Published var lastUpdatedText = ""
  @Published var isSending = false
  @Published var lastError = ""
  @Published var watchSessionActive = false
  /// Latest heart rate sample from Health (Apple Watch → Health on iPhone).
  @Published var latestAppleHealthHeartRateBpm: Double?
  /// When BPM is set: short time string ("3:42 PM"). When nil: status / empty-state message.
  @Published var appleHealthHeartRateDetail: String = ""
  /// Mirrors server brightness for the lamp slider (0…255).
  @Published var lampBrightness: Double = 120
  @Published var lampPowerOn = true
  @Published var blinkEnabled = false
  @Published var blinkBpm: Double = 72

  /// Increments on each manual lamp request so slower responses cannot overwrite newer state.
  private var manualLampGeneration = 0
  private var moodInsightGeneration = 0

  /// Last watch/analyze window — sent to explain-mood when present (cleared on manual lamp / mood tile pick).
  private var insightRestingBpm: Double?
  private var insightRecentBpms: [Double]?
  private var insightClassifierReason: String?
  private var lastAnalyzeSource = ""

  private let knownMoods = Set(["calm", "stressed", "happy", "sad"])

  private let baseline = HealthBaselineReader()
  private let api = CardiacAPIClient()

  private let iso8601WithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
  }()

  override init() {
    super.init()
    activateSessionIfNeeded()
  }

  private func activateSessionIfNeeded() {
    guard WCSession.isSupported() else {
      authorizationStatus = "WatchConnectivity unsupported on simulator"
      return
    }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func authorizeHealthIfNeeded() async {
    lastError = ""
    do {
      try await baseline.requestAuthorization()
      authorizationStatus = "Health authorized"
      await refreshLatestHeartRateFromHealth()
    } catch {
      authorizationStatus = "Health authorization failed"
      lastError = String(describing: error)
    }
  }

  /// Loads the most recent heart rate quantity sample from HealthKit (same data you see in the Health app).
  func refreshLatestHeartRateFromHealth() async {
    guard baseline.isHealthDataAvailable() else {
      latestAppleHealthHeartRateBpm = nil
      appleHealthHeartRateDetail = "Health not available on this device."
      return
    }

    let status = baseline.heartRateReadAuthorizationStatus()
    if status == .sharingDenied {
      latestAppleHealthHeartRateBpm = nil
      appleHealthHeartRateDetail = "Heart rate access denied — enable in Settings › Privacy & Security › Health."
      return
    }

    if let sample = await baseline.latestHeartRateSample() {
      latestAppleHealthHeartRateBpm = sample.bpm
      let t = DateFormatter.localizedString(from: sample.endDate, dateStyle: .none, timeStyle: .short)
      appleHealthHeartRateDetail = "Updated \(t)"
      return
    }

    latestAppleHealthHeartRateBpm = nil
    if status == .notDetermined {
      appleHealthHeartRateDetail = "Tap Health access below to read heart rate from Health."
    } else {
      appleHealthHeartRateDetail = "No heart rate in Health yet. Sync your Apple Watch or record a workout."
    }
  }

  func ingestWatchPayload(_ userInfo: [String: Any]) async {
    lastError = ""
    guard let bpmsUntyped = userInfo["bpms"] as? [Any] else {
      lastError = "missing bpms"
      return
    }
    let bpms = bpmsUntyped.compactMap { ($0 as? NSNumber)?.doubleValue }
    guard bpms.count >= 3 else {
      lastError = "too few bpms"
      return
    }

    let timestamps: [String]
    if let ts = userInfo["timestamps"] as? [String], ts.count >= bpms.count {
      timestamps = ts
    } else {
      let now = ISO8601DateFormatter().string(from: Date())
      timestamps = bpms.map { _ in now }
    }

    await runAnalyze(bpms: bpms, timestamps: timestamps)
  }

  private func runAnalyze(bpms: [Double], timestamps: [String]) async {
    isSending = true
    defer { isSending = false }

    let resting = await baseline.latestRestingBpm() ?? Config.defaultRestingBpm

    var samples: [HRSampleDTO] = []
    for i in bpms.indices {
      let t = i < timestamps.count ? timestamps[i] : iso8601WithFraction.string(from: Date())
      samples.append(HRSampleDTO(t: t, bpm: bpms[i]))
    }

    do {
      let resp = try await api.analyze(deviceId: Config.deviceId, restingBpm: resting, samples: samples)
      insightRestingBpm = resting
      insightRecentBpms = bpms
      applyAnalyzeResponse(resp)
      await refreshMoodInsight(selectedFallbackMood: resp.mood)
    } catch {
      lastError = String(describing: error)
    }
  }

  func applyAnalyzeResponse(_ resp: AnalyzeResponseBody) {
    lastMood = resp.mood
    lastLabel = resp.label ?? resp.mood
    lastColorHex = resp.color
    lastReason = resp.reason ?? ""
    insightClassifierReason = resp.reason
    lastAnalyzeSource = resp.source ?? ""
    lampBrightness = Double(resp.brightness)
    if let v = resp.powerOn { lampPowerOn = v }
    if let v = resp.blinkEnabled { blinkEnabled = v }
    if let v = resp.blinkBpm { blinkBpm = min(220, max(30, v)) }
    lastUpdatedText = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
  }

  /// Clears Watch/analyze HR context when the user picks a mood tile so explanations switch to everyday hints until the next analyze.
  func clearInsightHeartContextForManualSelection() {
    insightRestingBpm = nil
    insightRecentBpms = nil
    insightClassifierReason = nil
  }

  func refreshMoodInsight(selectedFallbackMood: String = "calm") async {
    moodInsightGeneration += 1
    let token = moodInsightGeneration
    let moodKey =
      lastMood != "—" && knownMoods.contains(lastMood) ? lastMood : selectedFallbackMood

    do {
      let caption = try await api.explainMoodInsight(
        deviceId: Config.deviceId,
        mood: moodKey,
        localDate: Self.localCalendarDateString(),
        timeZoneId: TimeZone.current.identifier,
        restingBpm: insightRestingBpm,
        recentBpms: insightRecentBpms,
        classifierReason: insightClassifierReason,
        analyzeSource: lastAnalyzeSource.isEmpty ? nil : lastAnalyzeSource
      )
      guard token == moodInsightGeneration else { return }
      moodInsight = caption
    } catch {
      guard token == moodInsightGeneration else { return }
      moodInsight = Self.localFallbackInsight(mood: moodKey)
    }
  }

  private static func localCalendarDateString() -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
  }

  private static func localFallbackInsight(mood: String) -> String {
    switch mood.lowercased() {
    case "stressed":
      return "Stressed tones can mirror a hectic stretch — weather, deadlines, or just too much coffee."
    case "happy":
      return "Happy glow fits sunny moods — weekend plans, good news, or the simple lift of a brighter hour."
    case "sad":
      return "Softer blues nod to quiet moments — rainy windows, long evenings, or needing gentler light."
    default:
      return "Calm gold suits slow breathing — cozy indoors, a pause between tasks, or a softer slice of the day."
    }
  }

  /// Push lamp color/brightness to the server; ESP32 picks it up on the next `/v1/cardiac/latest` poll.
  /// Does not toggle `isSending` (no blocking spinner); stale completions are ignored via generation.
  func pushManualLamp(
    mood: String,
    brightness: Int,
    colorHexOverride: String?,
    powerOn: Bool,
    blinkEnabled: Bool,
    blinkBpm: Double,
    moodLabel: String?
  ) async {
    manualLampGeneration += 1
    let token = manualLampGeneration

    let b = min(255, max(0, brightness))
    let bpmClamped = min(220, max(30, blinkBpm))
    do {
      let resp = try await api.manualLamp(
        deviceId: Config.deviceId,
        mood: mood,
        brightness: b,
        colorHex: colorHexOverride,
        powerOn: powerOn,
        blinkEnabled: blinkEnabled,
        blinkBpm: bpmClamped,
        moodLabel: moodLabel
      )
      guard token == manualLampGeneration else { return }
      insightRestingBpm = nil
      insightRecentBpms = nil
      applyAnalyzeResponse(resp)
      lastError = ""
      await refreshMoodInsight(selectedFallbackMood: mood)
    } catch {
      guard token == manualLampGeneration else { return }
      lastError = String(describing: error)
    }
  }
}

extension MoodHub: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      if activationState == .activated {
        self.watchSessionActive = true
      }
      if let error {
        self.lastError = error.localizedDescription
      }
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    WCSession.default.activate()
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
    Task { @MainActor in
      await self.ingestWatchPayload(userInfo)
    }
  }
}

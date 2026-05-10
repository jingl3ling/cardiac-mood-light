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
  @Published var lampBrightness: Double = Config.defaultLampBrightness
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

  /// Latest resting HR from HealthKit (for explain-mood when Watch/analyze context is absent).
  private var healthSnapshotRestingBpm: Double?
  /// Avoid re-running `/analyze` on every poll when the newest HR sample is unchanged.
  private var lastHealthAutoAnalyzedNewestSampleEnd: Date?
  /// Resting-only fallback when no instantaneous HR samples exist.
  private var lastHealthRestingAnalyzeKey: String?

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

  /// Loads the latest HR-related value from HealthKit.
  /// Important: read authorization cannot be trusted from `authorizationStatus` alone — Apple recommends querying first.
  /// ECG and **Heart Rate** are separate toggles per app in Health; another app seeing ECG does not grant HR here.
  ///
  /// **Display** uses `latestHeartRateSample()` so “Latest from Health” shows the true newest heartbeat row from HealthKit.
  /// `/analyze` uses a short sample window when present; otherwise a single pulse or resting-only path.
  func refreshLatestHeartRateFromHealth() async {
    guard baseline.isHealthDataAvailable() else {
      latestAppleHealthHeartRateBpm = nil
      appleHealthHeartRateDetail = "Health not available on this device."
      healthSnapshotRestingBpm = nil
      return
    }

    healthSnapshotRestingBpm = await baseline.latestRestingBpm()

    let pulse = await baseline.latestHeartRateSample()
    if let pulse {
      latestAppleHealthHeartRateBpm = pulse.bpm
      let t = DateFormatter.localizedString(from: pulse.endDate, dateStyle: .none, timeStyle: .short)
      appleHealthHeartRateDetail = "Updated \(t)"
    } else if let resting = healthSnapshotRestingBpm {
      latestAppleHealthHeartRateBpm = resting
      appleHealthHeartRateDetail = "Latest resting heart rate in Health"
    } else {
      latestAppleHealthHeartRateBpm = nil
      switch baseline.heartRateReadAuthorizationStatus() {
      case .notDetermined:
        appleHealthHeartRateDetail =
          "Allow Heart Rate when iOS prompts, or Settings › Health › Data Access & Devices › Cardiac Mood."
      case .sharingDenied:
        appleHealthHeartRateDetail =
          "Heart Rate is turned off for this app. Settings › Health › Data Access & Devices › Cardiac Mood — enable Heart Rate (separate from ECG)."
      default:
        appleHealthHeartRateDetail =
          "No heart rate data yet. Sync Apple Watch, or open Health › Heart Rate. Note: ECG access in another app is different from Heart Rate here."
      }
    }

    let recent = await baseline.recentHeartRateBpmsOldestFirst(limit: 16)
    if let newest = recent.last {
      let newestEnd = newest.endDate
      let shouldAutoAnalyze = lastHealthAutoAnalyzedNewestSampleEnd != newestEnd
      if shouldAutoAnalyze {
        let bpms = recent.map(\.bpm)
        let ts = recent.map { iso8601WithFraction.string(from: $0.endDate) }
        let ok = await runAnalyze(bpms: bpms, timestamps: ts)
        if ok {
          lastHealthAutoAnalyzedNewestSampleEnd = newestEnd
          lastHealthRestingAnalyzeKey = nil
        }
      }
      await syncBlinkBpmFromLatestHealthAndPushIfNeeded()
      return
    }

    if let pulse {
      let pulseEnd = pulse.endDate
      if lastHealthAutoAnalyzedNewestSampleEnd != pulseEnd {
        let ok = await runAnalyze(
          bpms: [pulse.bpm],
          timestamps: [iso8601WithFraction.string(from: pulse.endDate)]
        )
        if ok {
          lastHealthAutoAnalyzedNewestSampleEnd = pulseEnd
          lastHealthRestingAnalyzeKey = nil
        }
      }
      await syncBlinkBpmFromLatestHealthAndPushIfNeeded()
      return
    }

    if let resting = healthSnapshotRestingBpm {
      let key = String(format: "%.1f", resting)
      let shouldAnalyze = lastHealthRestingAnalyzeKey != key
      if shouldAnalyze {
        let t = iso8601WithFraction.string(from: Date())
        let ok = await runAnalyze(bpms: [resting], timestamps: [t])
        if ok {
          lastHealthRestingAnalyzeKey = key
          lastHealthAutoAnalyzedNewestSampleEnd = nil
        }
      }
    }
    await syncBlinkBpmFromLatestHealthAndPushIfNeeded()
  }

  func ingestWatchPayload(_ userInfo: [String: Any]) async {
    lastError = ""
    guard let bpmsUntyped = userInfo["bpms"] as? [Any] else {
      lastError = "missing bpms"
      return
    }
    let bpms = bpmsUntyped.compactMap { ($0 as? NSNumber)?.doubleValue }
    guard bpms.count >= 1 else {
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

    let ok = await runAnalyze(bpms: bpms, timestamps: timestamps)
    if ok, let last = bpms.last {
      let c = min(220.0, max(30.0, last))
      blinkBpm = c
      await pushManualLamp(
        mood: moodKeyForLampAPI(),
        brightness: Int(min(255, max(0, lampBrightness.rounded()))),
        colorHexOverride: optionalColorHexForLampSync(),
        powerOn: lampPowerOn,
        blinkEnabled: blinkEnabled,
        blinkBpm: blinkBpm,
        moodLabel: nil,
        preserveInsightContext: true
      )
    }
  }

  private func moodKeyForLampAPI() -> String {
    knownMoods.contains(lastMood) ? lastMood : "calm"
  }

  private func optionalColorHexForLampSync() -> String? {
    let h = lastColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard h.hasPrefix("#"), h.count == 7 else { return nil }
    return h
  }

  /// Blink BPM tracks “Latest from Health”; push lamp state without clearing HR insight context.
  private func syncBlinkBpmFromLatestHealthAndPushIfNeeded() async {
    guard let hr = latestAppleHealthHeartRateBpm else { return }
    let clamped = min(220.0, max(30.0, hr))
    guard abs(clamped - blinkBpm) >= 0.2 else { return }
    blinkBpm = clamped
    await pushManualLamp(
      mood: moodKeyForLampAPI(),
      brightness: Int(min(255, max(0, lampBrightness.rounded()))),
      colorHexOverride: optionalColorHexForLampSync(),
      powerOn: lampPowerOn,
      blinkEnabled: blinkEnabled,
      blinkBpm: blinkBpm,
      moodLabel: nil,
      preserveInsightContext: true
    )
  }

  @discardableResult
  private func runAnalyze(bpms: [Double], timestamps: [String]) async -> Bool {
    isSending = true
    defer { isSending = false }

    let resting = await baseline.latestRestingBpm() ?? Config.defaultRestingBpm

    var samples: [HRSampleDTO] = []
    for i in bpms.indices {
      let t = i < timestamps.count ? timestamps[i] : iso8601WithFraction.string(from: Date())
      samples.append(HRSampleDTO(t: t, bpm: bpms[i]))
    }

    do {
      let resp = try await api.analyze(
        deviceId: Config.deviceId,
        restingBpm: resting,
        samples: samples,
        timeZoneId: TimeZone.current.identifier
      )
      insightRestingBpm = resting
      insightRecentBpms = bpms
      applyAnalyzeResponse(resp)
      return true
    } catch {
      lastError = String(describing: error)
      return false
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

  func refreshMoodInsight(selectedFallbackMood: String = "calm", customUserMoodName: String? = nil) async {
    moodInsightGeneration += 1
    let token = moodInsightGeneration
    let moodKey =
      lastMood != "—" && knownMoods.contains(lastMood) ? lastMood : selectedFallbackMood

    let restingForExplain = insightRestingBpm ?? healthSnapshotRestingBpm
    let recentForExplain: [Double]? = {
      if let r = insightRecentBpms, !r.isEmpty { return r }
      if let b = latestAppleHealthHeartRateBpm { return [b] }
      return nil
    }()
    let sourceForExplain: String? = {
      if let r = insightRecentBpms, !r.isEmpty {
        return lastAnalyzeSource.isEmpty ? nil : lastAnalyzeSource
      }
      if latestAppleHealthHeartRateBpm != nil {
        return "apple_health"
      }
      return lastAnalyzeSource.isEmpty ? nil : lastAnalyzeSource
    }()

    do {
      let caption = try await api.explainMoodInsight(
        deviceId: Config.deviceId,
        mood: moodKey,
        localDate: Self.localCalendarDateString(),
        timeZoneId: TimeZone.current.identifier,
        restingBpm: restingForExplain,
        recentBpms: recentForExplain,
        classifierReason: insightClassifierReason,
        analyzeSource: sourceForExplain,
        customMoodName: customUserMoodName
      )
      guard token == moodInsightGeneration else { return }
      moodInsight = caption
    } catch {
      guard token == moodInsightGeneration else { return }
      moodInsight = Self.localFallbackInsight(mood: moodKey, customName: customUserMoodName)
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

  /// Mirrors server `_label_likely_gibberish` so offline copy matches API fallback tone.
  private static func customLabelLooksLikeGibberish(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let letters = trimmed.filter { $0.isLetter }
    guard letters.count >= 2 else { return true }
    let low = String(letters).lowercased()
    if low.count >= 2, Set(low).count == 1 { return true }
    let vowelCount = low.filter { "aeiouy".contains($0) }.count
    if low.count >= 4, vowelCount == 0 { return true }
    if low.count >= 5, Double(vowelCount) / Double(low.count) < 0.12 { return true }
    let alphaChars = trimmed.filter { $0.isLetter }
    if alphaChars.count >= 5 {
      let up = alphaChars.map { $0.isUppercase }
      var transitions = 0
      for i in 0..<(up.count - 1) where up[i] != up[i + 1] {
        transitions += 1
      }
      if transitions >= max(3, Int(Double(up.count) * 0.4)) { return true }
    }
    return false
  }

  private static func localFallbackInsight(mood: String, customName: String?) -> String {
    if let raw = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      let c = String(raw.prefix(48))
      if customLabelLooksLikeGibberish(c) {
        return
          "I'm sure you feel this way for a certain reason—no need to put it into perfect words."
      }
      let low = c.lowercased()
      if low.contains("scar") || low.contains("fear") || low.contains("afraid") || low.contains("panic") {
        return "For «\(c)»: sudden noise, shadows, or a racing mind can spike that feeling—the lamp keeps the edge soft."
      }
      if low.contains("anger") || low.contains("mad") || low.contains("furious") || low.contains("rage") {
        return "For «\(c)»: friction, unfair surprises, or tight deadlines often fan the heat—breathe with the glow."
      }
      if low.contains("peace") || low.contains("calm") || low.contains("relax") {
        return "For «\(c)»: slow breathing, a cozy corner, or winding down fits this light."
      }
      let m = mood.lowercased()
      let tail: String = {
        switch m {
        case "stressed": return "overload, deadlines, or a nervous system on high alert"
        case "happy": return "good news, bright company, or plain relief today"
        case "sad": return "a heavy hour, goodbyes, or quiet tiredness"
        default: return "needing less noise, a slower breath, or a softer corner"
        }
      }()
      return "If «\(c)» fits you, this \(m) light can echo \(tail)—take what resonates."
    }
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
    moodLabel: String?,
    preserveInsightContext: Bool = false
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
      if !preserveInsightContext {
        insightRestingBpm = nil
        insightRecentBpms = nil
      }
      applyAnalyzeResponse(resp)
      lastError = ""
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

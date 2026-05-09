import Combine
import Foundation
import SwiftUI
import WatchConnectivity

@MainActor
final class MoodHub: NSObject, ObservableObject {
  @Published var authorizationStatus = "Tap to authorize Health"
  @Published var lastMood = "—"
  @Published var lastLabel = "—"
  @Published var lastColorHex = "#808080"
  @Published var lastReason = ""
  @Published var lastUpdatedText = ""
  @Published var isSending = false
  @Published var lastError = ""
  @Published var watchSessionActive = false
  /// Mirrors server brightness for the lamp slider (0…255).
  @Published var lampBrightness: Double = 180

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
    } catch {
      authorizationStatus = "Health authorization failed"
      lastError = String(describing: error)
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
      applyAnalyzeResponse(resp)
    } catch {
      lastError = String(describing: error)
    }
  }

  func applyAnalyzeResponse(_ resp: AnalyzeResponseBody) {
    lastMood = resp.mood
    lastLabel = resp.label ?? resp.mood
    lastColorHex = resp.color
    lastReason = resp.reason ?? ""
    lampBrightness = Double(resp.brightness)
    lastUpdatedText = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
  }

  /// Push lamp color/brightness to the server; ESP32 picks it up on the next `/v1/cardiac/latest` poll.
  func pushManualLamp(mood: String, brightness: Int, colorHexOverride: String?) async {
    lastError = ""
    isSending = true
    defer { isSending = false }

    let b = min(255, max(0, brightness))
    do {
      let resp = try await api.manualLamp(
        deviceId: Config.deviceId,
        mood: mood,
        brightness: b,
        colorHex: colorHexOverride
      )
      applyAnalyzeResponse(resp)
    } catch {
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

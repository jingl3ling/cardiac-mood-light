import Foundation
import SwiftUI

@MainActor
final class ViewerViewModel: ObservableObject {
  @Published var lampState: LatestStateDTO?
  @Published var statusMessage = ""

  private let api = CardiacAPIClient()
  private var pollTask: Task<Void, Never>?
  /// Seconds between automatic GET `/latest` polls (plan: 5–10s).
  private let pollIntervalSeconds: Double = 6

  func startPolling() {
    pollTask?.cancel()
    pollTask = Task {
      while !Task.isCancelled {
        await refresh()
        let ns = UInt64(max(3, pollIntervalSeconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  func refresh() async {
    do {
      let s = try await api.getLatest(deviceId: Config.deviceId)
      lampState = s
      statusMessage = ""
    } catch {
      statusMessage = "Could not load lamp state. Check network and API key."
      lampState = nil
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
    } catch {
      statusMessage = "Blink update failed."
    }
  }
}

import Foundation
import SwiftUI

@MainActor
final class ViewerViewModel: ObservableObject {
  @Published var lampState: LatestStateDTO?
  @Published var statusMessage = ""

  private let api = CardiacAPIClient()
  private var pollTask: Task<Void, Never>?

  /// Little Lamp timestamps server mutations via `FamilySyncBeacon`; we skip redundant GET work until something newer arrives.
  private var handledBeaconThrough: TimeInterval = 0

  /// Watch app-group pings at ~1 Hz (cheap reads); unconditional `/latest` less often so radio stays asleep when nothing changed.
  private let fastWakeCheckSeconds: Double = 1
  /// Every N fast ticks (~55s default), GET `/latest` anyway (missed beacons / other clients).
  private let unconditionalRefreshEveryTicks = 55

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
  }

  /// Immediate check when MoodViewer foregrounds — Little Lamp bumps a shared beacon on each successful API write.
  func pollMainAppTriggeredRefreshIfNeeded() async {
    let stamp = FamilySyncBeacon.lastMainAppServerMutationAt()
    if stamp <= handledBeaconThrough + 0.000_1 {
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

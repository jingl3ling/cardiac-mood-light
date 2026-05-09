import Foundation
import WatchConnectivity

final class WatchConnectivitySender: NSObject, ObservableObject {
  static let shared = WatchConnectivitySender()

  override private init() {
    super.init()
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func sendBpmWindow(bpms: [Double], dates: [Date]) {
    guard WCSession.default.activationState == .activated else { return }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    iso.timeZone = TimeZone(secondsFromGMT: 0)
    let ts = dates.map { iso.string(from: $0) }
    let payload: [String: Any] = [
      "bpms": bpms.map { NSNumber(value: $0) },
      "timestamps": ts,
      "deviceId": Config.deviceId,
    ]
    WCSession.default.transferUserInfo(payload)
  }
}

extension WatchConnectivitySender: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    // no-op; debug in UI if needed
  }
}

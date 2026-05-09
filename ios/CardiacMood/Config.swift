import Foundation

enum Config {
  /// Base URL only (no trailing slash), e.g. http://192.168.1.10:8080
  static let baseURL = URL(string: "http://127.0.0.1:8080")!

  /// Must match server `API_KEY` (can be empty on server → no auth)
  static let apiKey = "dev-change-me"

  /// Must match ESP32 DEVICE_ID when sharing one lamp identity
  static let deviceId = "device-001"

  /// Used when HealthKit has no resting heart rate sample yet
  static let defaultRestingBpm = 72.0
}

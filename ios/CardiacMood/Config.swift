import Foundation

enum Config {
  /// Base URL only (no trailing slash), including scheme (https for production).
  static let baseURL = URL(string: "https://cardiac-mood-light-production.up.railway.app")!

  /// Must match server `API_KEY` (can be empty on server → no auth)
  static let apiKey = "dev-change-me"

  /// Must match ESP32 DEVICE_ID when sharing one lamp identity
  static let deviceId = "device-001"

  /// Used when HealthKit has no resting heart rate sample yet
  static let defaultRestingBpm = 72.0

  /// Default lamp brightness (0…255) before any server/analyze response.
  static let defaultLampBrightness: Double = 120
}

import Foundation

/// Shared app-group bump so MoodViewer can GET `/latest` right after Little Lamp updates the server (same phone).
enum FamilySyncBeacon {
  /// Must match the App Group in both targets’ entitlements.
  static let suiteId = "group.com.cardiacmood.family"
  private static let lastPushKey = "littleLampMainAppLastServerMutationAt"

  static func markMainAppDidMutateServer() {
    guard let ud = UserDefaults(suiteName: suiteId) else { return }
    ud.set(Date().timeIntervalSince1970, forKey: lastPushKey)
  }

  static func lastMainAppServerMutationAt() -> TimeInterval {
    UserDefaults(suiteName: suiteId)?.double(forKey: lastPushKey) ?? 0
  }
}

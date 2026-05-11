import CoreFoundation
import Foundation

/// Wakes MoodViewer right after Little Lamp writes lamp state (same device). Uses Darwin notify so it still works if App Group `UserDefaults` is unavailable.
enum FamilySyncBeacon {
  /// Must match the App Group in both targets’ entitlements.
  static let suiteId = "group.com.cardiacmood.family"
  private static let lastPushKey = "littleLampMainAppLastServerMutationAt"

  /// Same string in Cardiac Mood + MoodViewer — `CFNotificationCenter` Darwin deliver.
  static let lampMutationDarwinName = "com.cardiacmood.familyLampStateDidChange"

  static func markMainAppDidMutateServer() {
    UserDefaults(suiteName: suiteId)?.set(Date().timeIntervalSince1970, forKey: lastPushKey)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(lampMutationDarwinName as CFString),
      nil,
      nil,
      true
    )
  }

  static func lastMainAppServerMutationAt() -> TimeInterval {
    UserDefaults(suiteName: suiteId)?.double(forKey: lastPushKey) ?? 0
  }
}

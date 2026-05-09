import SwiftUI

@main
struct CardiacMoodWatchApp: App {
  init() {
    WatchConnectivitySender.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

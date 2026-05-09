import SwiftUI

@main
struct CardiacMoodApp: App {
  @StateObject private var hub = MoodHub()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(hub)
    }
  }
}

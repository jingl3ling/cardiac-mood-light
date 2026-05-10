import SwiftUI

@main
struct MoodViewerApp: App {
  @StateObject private var model = ViewerViewModel()

  var body: some Scene {
    WindowGroup {
      ViewerRootView()
        .environmentObject(model)
    }
  }
}

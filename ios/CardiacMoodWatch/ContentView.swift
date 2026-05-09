import SwiftUI

struct ContentView: View {
  @StateObject private var buffer = WorkoutHeartBuffer()

  var body: some View {
    VStack(spacing: 10) {
      Text("Cardiac Mood")
        .font(.headline)

      Text(buffer.authorizationStatus)
        .font(.caption2)
        .multilineTextAlignment(.center)

      if let bpm = buffer.bpm {
        Text("\(Int(round(bpm))) BPM")
          .font(.system(.title2, design: .rounded).weight(.bold))
      } else {
        Text("— BPM")
          .foregroundStyle(.secondary)
      }

      Text("Buffer: \(buffer.bufferCount)/\(Config.windowSize)")
        .font(.caption2)
        .foregroundStyle(.secondary)

      if buffer.isRunning {
        Button("Stop session") {
          Task { await buffer.stop() }
        }
        .tint(.red)
      } else {
        Button("Start session") {
          Task { await buffer.start() }
        }
        .tint(.green)
      }
    }
    .padding()
    .task {
      await buffer.requestAuthorization()
    }
  }
}

#Preview {
  ContentView()
}

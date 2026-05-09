import Foundation
import HealthKit

@MainActor
final class WorkoutHeartBuffer: NSObject, ObservableObject {
  @Published var authorizationStatus = "Not requested"
  @Published var isRunning = false
  @Published var bpm: Double?
  @Published var bufferCount = 0

  private let healthStore = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?

  private var readings: [(Date, Double)] = []
  private var lastFlush = Date()

  private let sender = WatchConnectivitySender.shared

  func requestAuthorization() async {
    guard HKHealthStore.isHealthDataAvailable() else {
      authorizationStatus = "Health not available"
      return
    }
    guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
      authorizationStatus = "HR type missing"
      return
    }
    do {
      try await healthStore.requestAuthorization(toShare: [], read: [hrType])
      authorizationStatus = "Authorized"
    } catch {
      authorizationStatus = "Auth failed"
    }
  }

  func start() async {
    if isRunning { return }
    let config = HKWorkoutConfiguration()
    config.activityType = .other
    config.locationType = .indoor

    do {
      let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
      let builder = session.associatedWorkoutBuilder()
      builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

      session.delegate = self
      builder.delegate = self

      self.session = session
      self.builder = builder

      let startDate = Date()
      session.startActivity(with: startDate)
      try await builder.beginCollection(at: startDate)

      readings.removeAll()
      lastFlush = Date()
      isRunning = true
    } catch {
      isRunning = false
    }
  }

  func stop() async {
    guard let session, let builder else { return }
    session.end()

    let end = Date()
    do {
      try await builder.endCollection(at: end)
      try await builder.finishWorkout()
    } catch {
      // ignore
    }

    self.session = nil
    self.builder = nil
    isRunning = false
    flushIfNeeded(force: true)
  }

  private func handleHeartRateSample(_ quantity: HKQuantity) {
    let unit = HKUnit(from: "count/min")
    let value = quantity.doubleValue(for: unit)
    bpm = value
    let now = Date()
    readings.append((now, value))
    bufferCount = readings.count

    if readings.count >= Config.windowSize {
      flushIfNeeded(force: true)
    } else {
      flushIfNeeded(force: false)
    }
  }

  private func flushIfNeeded(force: Bool) {
    let now = Date()
    if !force && now.timeIntervalSince(lastFlush) < Config.flushSeconds {
      return
    }
    guard readings.count >= 3 else { return }

    let slice = readings.suffix(Config.windowSize)
    let dates = slice.map(\.0)
    let bpms = slice.map(\.1)

    readings.removeAll(keepingCapacity: true)
    lastFlush = now
    bufferCount = 0

    sender.sendBpmWindow(bpms: bpms, dates: dates)
  }
}

extension WorkoutHeartBuffer: HKWorkoutSessionDelegate {
  nonisolated func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState,
    from fromState: HKWorkoutSessionState,
    date: Date
  ) {}

  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

extension WorkoutHeartBuffer: HKLiveWorkoutBuilderDelegate {
  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

  nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
    if !collectedTypes.contains(hrType) { return }
    guard let stats = workoutBuilder.statistics(for: hrType),
          let quantity = stats.mostRecentQuantity() else { return }

    Task { @MainActor in
      self.handleHeartRateSample(quantity)
    }
  }
}

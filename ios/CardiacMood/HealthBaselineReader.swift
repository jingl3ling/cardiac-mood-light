import Foundation
import HealthKit

/// Reads resting and latest heart rate from HealthKit (Watch writes samples to Health on iPhone).
final class HealthBaselineReader {
  private let healthStore = HKHealthStore()

  private static let heartRateUnit = HKUnit(from: "count/min")

  func isHealthDataAvailable() -> Bool {
    HKHealthStore.isHealthDataAvailable()
  }

  func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw NSError(domain: "Health", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health not available"])
    }
    guard let resting = HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
          let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)
    else {
      throw NSError(domain: "Health", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing type"])
    }
    try await healthStore.requestAuthorization(toShare: [], read: [resting, heartRate])
  }

  /// Read authorization status for heart rate (same session as Watch → Health samples).
  func heartRateReadAuthorizationStatus() -> HKAuthorizationStatus {
    guard let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
      return .notDetermined
    }
    return healthStore.authorizationStatus(for: heartRate)
  }

  /// Latest resting HR sample, if any.
  func latestRestingBpm() async -> Double? {
    guard let resting = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }

    return await withCheckedContinuation { continuation in
      let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
      let query = HKSampleQuery(sampleType: resting, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
        guard let qty = samples?.first as? HKQuantitySample else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: qty.quantity.doubleValue(for: Self.heartRateUnit))
      }
      healthStore.execute(query)
    }
  }

  /// Most recent heart rate sample (any source), typically from Apple Watch via Health.
  func latestHeartRateSample() async -> (bpm: Double, endDate: Date)? {
    guard let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }

    return await withCheckedContinuation { continuation in
      let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
      let query = HKSampleQuery(sampleType: heartRate, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
        guard let qty = samples?.first as? HKQuantitySample else {
          continuation.resume(returning: nil)
          return
        }
        let bpm = qty.quantity.doubleValue(for: Self.heartRateUnit)
        continuation.resume(returning: (bpm, qty.endDate))
      }
      healthStore.execute(query)
    }
  }
}

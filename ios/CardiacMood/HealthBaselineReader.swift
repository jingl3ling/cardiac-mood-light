import Foundation
import HealthKit

/// Reads the most recent resting heart rate from HealthKit (Watch-populated when available).
final class HealthBaselineReader {
  private let healthStore = HKHealthStore()

  func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw NSError(domain: "Health", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health not available"])
    }
    guard let resting = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
      throw NSError(domain: "Health", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing type"])
    }
    try await healthStore.requestAuthorization(toShare: [], read: [resting])
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
        let unit = HKUnit(from: "count/min")
        continuation.resume(returning: qty.quantity.doubleValue(for: unit))
      }
      healthStore.execute(query)
    }
  }
}

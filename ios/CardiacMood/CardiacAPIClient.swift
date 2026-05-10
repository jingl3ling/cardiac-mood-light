import Foundation

struct HRSampleDTO: Codable {
  let t: String
  let bpm: Double
}

struct AnalyzeRequestBody: Codable {
  let deviceId: String
  let restingBpm: Double?
  let samples: [HRSampleDTO]
  /// IANA id (e.g. `America/New_York`) so the server can fold in local time-of-day with single-BPM analyze.
  let timeZoneId: String?
}

struct AnalyzeResponseBody: Codable {
  let ok: Bool?
  let mood: String
  let label: String?
  let color: String
  let brightness: Int
  let reason: String?
  let source: String?
  let updatedAt: Double?
  let powerOn: Bool?
  let blinkEnabled: Bool?
  let blinkBpm: Double?
}

struct ExplainMoodRequestBody: Codable {
  let deviceId: String
  let mood: String
  let localDate: String
  let timeZoneId: String
  let restingBpm: Double?
  let recentBpms: [Double]?
  let classifierReason: String?
  let analyzeSource: String?
  /// User-entered mood name ("Customize mood"); optional.
  let customMoodName: String?
}

struct ExplainMoodResponseBody: Codable {
  let ok: Bool?
  let caption: String
}

struct ManualLampRequestBody: Codable {
  let deviceId: String
  let mood: String
  let brightness: Int
  /// When set, overrides palette color (`#RRGGBB`).
  let color: String?
  let powerOn: Bool
  let blinkEnabled: Bool
  let blinkBpm: Double
  /// When set, overrides preset mood label on the server.
  let moodLabel: String?
}

struct SyncBlinkRequestBody: Codable {
  let deviceId: String
  let blinkBpm: Double
  let blinkEnabled: Bool
}

enum CardiacAPIError: Error {
  case badStatus(Int)
  case decodeFailed
}

struct CardiacAPIClient {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func analyze(
    deviceId: String,
    restingBpm: Double?,
    samples: [HRSampleDTO],
    timeZoneId: String?
  ) async throws -> AnalyzeResponseBody {
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/analyze"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let body = AnalyzeRequestBody(deviceId: deviceId, restingBpm: restingBpm, samples: samples, timeZoneId: timeZoneId)
    req.httpBody = try JSONEncoder().encode(body)

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    return try JSONDecoder().decode(AnalyzeResponseBody.self, from: data)
  }

  func manualLamp(
    deviceId: String,
    mood: String,
    brightness: Int,
    colorHex: String?,
    powerOn: Bool,
    blinkEnabled: Bool,
    blinkBpm: Double,
    moodLabel: String?
  ) async throws -> AnalyzeResponseBody {
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/manual"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let bpm = min(220, max(30, blinkBpm))
    let body = ManualLampRequestBody(
      deviceId: deviceId,
      mood: mood,
      brightness: brightness,
      color: colorHex,
      powerOn: powerOn,
      blinkEnabled: blinkEnabled,
      blinkBpm: bpm,
      moodLabel: moodLabel
    )
    req.httpBody = try JSONEncoder().encode(body)

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    return try JSONDecoder().decode(AnalyzeResponseBody.self, from: data)
  }

  func syncBlink(deviceId: String, blinkBpm: Double, blinkEnabled: Bool) async throws -> AnalyzeResponseBody {
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/sync-blink"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let bpm = min(220, max(30, blinkBpm))
    let body = SyncBlinkRequestBody(deviceId: deviceId, blinkBpm: bpm, blinkEnabled: blinkEnabled)
    req.httpBody = try JSONEncoder().encode(body)

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    return try JSONDecoder().decode(AnalyzeResponseBody.self, from: data)
  }

  func explainMoodInsight(
    deviceId: String,
    mood: String,
    localDate: String,
    timeZoneId: String,
    restingBpm: Double?,
    recentBpms: [Double]?,
    classifierReason: String?,
    analyzeSource: String?,
    customMoodName: String?
  ) async throws -> String {
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/explain-mood"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let body = ExplainMoodRequestBody(
      deviceId: deviceId,
      mood: mood,
      localDate: localDate,
      timeZoneId: timeZoneId,
      restingBpm: restingBpm,
      recentBpms: recentBpms,
      classifierReason: classifierReason,
      analyzeSource: analyzeSource,
      customMoodName: customMoodName
    )
    req.httpBody = try JSONEncoder().encode(body)

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    let decoded = try JSONDecoder().decode(ExplainMoodResponseBody.self, from: data)
    return decoded.caption
  }
}

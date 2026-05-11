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

/// `GET /v1/cardiac/latest` — lamp state plus optional viewer fields from `viewer-context`.
struct LatestStateDTO: Codable {
  let mood: String
  let label: String?
  let color: String
  let brightness: Int
  let updatedAt: Double?
  let powerOn: Bool?
  let blinkEnabled: Bool?
  let blinkBpm: Double?
  let reportedHeartRateBpm: Double?
  let reportedHeartRateAt: Double?
  let moodInsight: String?
  let viewerContextUpdatedAt: Double?

  enum CodingKeys: String, CodingKey {
    case mood, label, color, brightness, updatedAt, powerOn, blinkEnabled, blinkBpm
    case reportedHeartRateBpm, reportedHeartRateAt, moodInsight, viewerContextUpdatedAt
  }

  init(
    mood: String,
    label: String?,
    color: String,
    brightness: Int,
    updatedAt: Double?,
    powerOn: Bool?,
    blinkEnabled: Bool?,
    blinkBpm: Double?,
    reportedHeartRateBpm: Double?,
    reportedHeartRateAt: Double?,
    moodInsight: String?,
    viewerContextUpdatedAt: Double?
  ) {
    self.mood = mood
    self.label = label
    self.color = color
    self.brightness = brightness
    self.updatedAt = updatedAt
    self.powerOn = powerOn
    self.blinkEnabled = blinkEnabled
    self.blinkBpm = blinkBpm
    self.reportedHeartRateBpm = reportedHeartRateBpm
    self.reportedHeartRateAt = reportedHeartRateAt
    self.moodInsight = moodInsight
    self.viewerContextUpdatedAt = viewerContextUpdatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mood = try c.decode(String.self, forKey: .mood)
    label = try c.decodeIfPresent(String.self, forKey: .label)
    color = try c.decode(String.self, forKey: .color)
    if let b = try? c.decode(Int.self, forKey: .brightness) {
      brightness = b
    } else if let d = try? c.decode(Double.self, forKey: .brightness) {
      brightness = Int(d.rounded())
    } else {
      brightness = 128
    }
    updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
    powerOn = try c.decodeIfPresent(Bool.self, forKey: .powerOn)
    blinkEnabled = try c.decodeIfPresent(Bool.self, forKey: .blinkEnabled)
    blinkBpm = try c.decodeIfPresent(Double.self, forKey: .blinkBpm)
    reportedHeartRateBpm = try c.decodeIfPresent(Double.self, forKey: .reportedHeartRateBpm)
    reportedHeartRateAt = try c.decodeIfPresent(Double.self, forKey: .reportedHeartRateAt)
    moodInsight = try c.decodeIfPresent(String.self, forKey: .moodInsight)
    viewerContextUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .viewerContextUpdatedAt)
  }
}

struct ViewerContextRequestBody: Codable {
  let deviceId: String
  let reportedHeartRateBpm: Double?
  /// Always sent so the server replaces any stale `moodInsight` (e.g. HR-only sync used to omit this key).
  let moodInsight: String
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

  func getLatest(deviceId: String) async throws -> LatestStateDTO {
    var components = URLComponents(
      url: Config.baseURL.appendingPathComponent("/v1/cardiac/latest"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "deviceId", value: deviceId)]
    var req = URLRequest(url: components.url!)
    req.httpMethod = "GET"
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    return try JSONDecoder().decode(LatestStateDTO.self, from: data)
  }

  /// Push Health BPM and mood line for the family viewer app (does not drive the lamp by itself).
  /// `moodInsightLine` must always reflect the primary app’s caption (Claude or fallback), including `""` to clear stale server text.
  func postViewerContext(
    deviceId: String,
    reportedHeartRateBpm: Double?,
    moodInsightLine: String
  ) async throws {
    let line = String(moodInsightLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    let hr = reportedHeartRateBpm.flatMap { raw -> Double? in
      guard raw.isFinite else { return nil }
      return min(230, max(30, raw))
    }
    guard hr != nil || !line.isEmpty else { return }
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/viewer-context"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let body = ViewerContextRequestBody(deviceId: deviceId, reportedHeartRateBpm: hr, moodInsight: line)
    req.httpBody = try JSONEncoder().encode(body)

    let (_, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
  }
}

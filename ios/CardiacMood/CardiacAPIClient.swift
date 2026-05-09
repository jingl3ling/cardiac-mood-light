import Foundation

struct HRSampleDTO: Codable {
  let t: String
  let bpm: Double
}

struct AnalyzeRequestBody: Codable {
  let deviceId: String
  let restingBpm: Double?
  let samples: [HRSampleDTO]
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

  func analyze(deviceId: String, restingBpm: Double?, samples: [HRSampleDTO]) async throws -> AnalyzeResponseBody {
    var req = URLRequest(url: Config.baseURL.appendingPathComponent("/v1/cardiac/analyze"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !Config.apiKey.isEmpty {
      req.setValue(Config.apiKey, forHTTPHeaderField: "x-api-key")
    }
    let body = AnalyzeRequestBody(deviceId: deviceId, restingBpm: restingBpm, samples: samples)
    req.httpBody = try JSONEncoder().encode(body)

    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw CardiacAPIError.badStatus(-1) }
    guard (200 ... 299).contains(http.statusCode) else { throw CardiacAPIError.badStatus(http.statusCode) }
    return try JSONDecoder().decode(AnalyzeResponseBody.self, from: data)
  }
}

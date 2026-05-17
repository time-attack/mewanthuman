import Foundation

@MainActor
class APIService: ObservableObject {
    static let shared = APIService()

    // MARK: - Configuration
    // Set this to your Railway deployment URL
    private let baseURL: String = {
        if let url = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String, !url.isEmpty {
            return url
        }
        // Default to Railway URL — update this with your actual deployment
        return "https://mewanthuman-production.up.railway.app"
    }()

    // MARK: - API Calls

    func startCall(reason: String) async throws -> CallResponse {
        let url = URL(string: "\(baseURL)/calls")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "source": "ios_app",
            "reason": reason
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed
        }
        return try JSONDecoder().decode(CallResponse.self, from: data)
    }

    func getSession(id: String) async throws -> SessionData {
        let url = URL(string: "\(baseURL)/sessions/\(id)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.sessionNotFound
        }
        return try JSONDecoder().decode(SessionData.self, from: data)
    }

    func getHistory() async throws -> [HistoryEntry] {
        let url = URL(string: "\(baseURL)/history")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    }

    func getActiveCalls() async throws -> [ActiveCall] {
        let url = URL(string: "\(baseURL)/active")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        return try JSONDecoder().decode([ActiveCall].self, from: data)
    }

    func registerDeviceToken(_ token: String) async {
        guard let url = URL(string: "\(baseURL)/register-device") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["token": token, "platform": "ios"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Stream session events via SSE
    func streamSession(id: String, onMessage: @escaping (StreamMessage) -> Void) -> URLSessionDataTask {
        let url = URL(string: "\(baseURL)/sessions/\(id)/stream")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: url) { data, _, _ in
            guard let data = data else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            // Parse SSE
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("data: ") {
                    let json = String(line.dropFirst(6))
                    if let msgData = json.data(using: .utf8),
                       let msg = try? JSONDecoder().decode(StreamMessage.self, from: msgData) {
                        DispatchQueue.main.async {
                            onMessage(msg)
                        }
                    }
                }
            }
        }
        task.resume()
        return task
    }
}

// MARK: - Models

struct CallResponse: Codable {
    let id: String?
    let sessionId: String
    let phone: String
    let status: String
}

struct SessionData: Codable {
    let messages: [SessionMessage]?
    let status: String?
    let phone: String?
    let reason: String?
    let startedAt: Int?
}

struct SessionMessage: Codable {
    let type: String
    let text: String?
    let role: String?
    let ts: Int?
}

struct HistoryEntry: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let phone: String
    let reason: String?
    let status: String
    let startedAt: Int?
    let endedAt: Int?
    let messageCount: Int?
}

struct ActiveCall: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let phone: String
    let reason: String?
    let status: String
    let startedAt: Int?
}

struct StreamMessage: Codable {
    let type: String
    let text: String?
    let role: String?
    let tool: String?
    let status: String?
}

enum APIError: Error, LocalizedError {
    case requestFailed
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Request failed"
        case .sessionNotFound: return "Session not found"
        }
    }
}

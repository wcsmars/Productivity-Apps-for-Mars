import Foundation
import Combine

enum CoachProvider: String, CaseIterable, Identifiable {
    case gemini
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .claude: "Claude"
        }
    }

    var keyFootnote: String {
        switch self {
        case .gemini: "Create a key at aistudio.google.com. Uses gemini-3.6-flash; availability and pricing depend on your account."
        case .claude: "Create a key at console.anthropic.com. Uses claude-haiku-4-5; availability and pricing depend on your account."
        }
    }
}

struct CoachMessage: Identifiable, Equatable {
    enum Role {
        case user, coach
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

private enum CoachError: LocalizedError {
    case missingKey
    case badURL
    case api(status: Int, detail: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add an API key in Settings first."
        case .badURL: "The provider endpoint is misconfigured."
        case .api(let status, let detail):
            "The provider returned an error (\(status)). \(detail.prefix(160))"
        case .badResponse: "The provider sent a response the coach couldn't read."
        }
    }
}

/// Sends focus statistics and questions to the selected provider and keeps
/// the conversation in memory.
@MainActor
final class CoachStore: ObservableObject {
    @Published private(set) var messages: [CoachMessage] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published private(set) var keyStorageError: String?

    @Published var provider: CoachProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: Self.providerKey)
            // Each provider keeps its own key, so switching never sends one
            // provider's secret to the other.
            isLoadingKey = true
            defer { isLoadingKey = false }
            do {
                apiKey = try credentials.load(provider: provider.rawValue)
                keyStorageError = nil
            } catch {
                apiKey = ""
                keyStorageError = error.localizedDescription
            }
        }
    }
    @Published var apiKey: String {
        didSet {
            guard !isLoadingKey else { return }
            do {
                try credentials.save(apiKey, provider: provider.rawValue)
                keyStorageError = nil
            } catch {
                keyStorageError = error.localizedDescription
            }
        }
    }

    private static let providerKey = "coach-provider"
    private let defaults: UserDefaults
    private let credentials: CoachCredentials
    private var isLoadingKey = false

    /// Keys pasted from a console often carry stray whitespace/newlines that
    /// would corrupt the auth header — always send the trimmed form.
    private var requestKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { !requestKey.isEmpty }

    init(defaults: UserDefaults = .standard, secrets: any CoachSecretStorage = CoachKeychain()) {
        self.defaults = defaults
        let credentials = CoachCredentials(defaults: defaults, secrets: secrets)
        self.credentials = credentials
        let storedProvider = defaults.string(forKey: Self.providerKey).flatMap(CoachProvider.init) ?? .gemini
        var storedKeys: [CoachProvider: String] = [:]
        var migrationError: String?
        for candidate in CoachProvider.allCases {
            do { storedKeys[candidate] = try credentials.load(provider: candidate.rawValue) }
            catch { migrationError = error.localizedDescription }
        }
        provider = storedProvider
        apiKey = storedKeys[storedProvider] ?? ""
        keyStorageError = migrationError
    }

    private static let systemPrompt = """
    You are the focus coach inside "Mars Focus", an iPhone app where the user blocks \
    distracting apps and websites during focus sessions. You receive the user's real \
    focus statistics with every message. Be a warm, practical coach: point at concrete \
    patterns in the data, celebrate streaks, suggest specific schedule tweaks, and keep \
    answers under 150 words. Never invent data that isn't in the stats.
    """

    /// Sends the message; returns the user's text when it could NOT be
    /// delivered (missing key, in-flight request, network/provider failure) so
    /// the caller can restore it to the input field instead of losing it.
    @discardableResult
    func send(_ text: String, context: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !isLoading else { return trimmed }
        guard isConfigured else {
            errorText = CoachError.missingKey.errorDescription
            return trimmed
        }
        messages.append(CoachMessage(role: .user, text: trimmed))
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let reply: String
            switch provider {
            case .gemini: reply = try await sendGemini(context: context)
            case .claude: reply = try await sendClaude(context: context)
            }
            messages.append(CoachMessage(role: .coach, text: reply))
            return nil
        } catch {
            errorText = error.localizedDescription
            // Remove the unanswered question so a retry doesn't send the
            // provider two consecutive copies of it.
            if messages.last?.role == .user {
                messages.removeLast()
            }
            return trimmed
        }
    }

    func clearConversation() {
        guard !isLoading else { return }
        messages = []
        errorText = nil
    }

    // MARK: - Providers

    private func systemText(context: String) -> String {
        Self.systemPrompt + "\n\nThe user's current stats:\n" + context
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoachError.badResponse }
        guard http.statusCode == 200 else {
            throw CoachError.api(status: http.statusCode,
                                 detail: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Google Gemini API: generativelanguage.googleapis.com
    private func sendGemini(context: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent") else {
            throw CoachError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestKey, forHTTPHeaderField: "x-goog-api-key")
        let contents: [[String: Any]] = messages.map { message in
            [
                "role": message.role == .user ? "user" : "model",
                "parts": [["text": message.text]],
            ]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemText(context: context)]]],
            "contents": contents,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw CoachError.badResponse
        }
        let text = parts.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw CoachError.badResponse }
        return text
    }

    /// Anthropic Messages API (see platform.claude.com/docs).
    private func sendClaude(context: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw CoachError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let history: [[String: Any]] = messages.map { message in
            [
                "role": message.role == .user ? "user" : "assistant",
                "content": message.text,
            ]
        }
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1024,
            "system": systemText(context: context),
            "messages": history,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw CoachError.badResponse
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw CoachError.badResponse }
        return text
    }
}

#if DEBUG
extension CoachStore {
    /// Populates a canned conversation for UI screenshots — no network involved.
    func seedDemoConversation() {
        guard messages.isEmpty else { return }
        messages = [
            CoachMessage(role: .user, text: "How am I doing this week?"),
            CoachMessage(role: .coach, text: """
            Strong week! You're on a 2-day streak and averaging about 90 focused \
            minutes a day — your Morning Focus schedule is clearly doing the heavy \
            lifting. One pattern to watch: two of your evening sessions ended early. \
            Try shortening Wind Down to 60 minutes so it's easier to finish, then \
            extend it once completing feels automatic.
            """),
        ]
    }
}
#endif

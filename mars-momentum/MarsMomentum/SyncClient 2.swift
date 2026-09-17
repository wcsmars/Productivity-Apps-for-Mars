import Foundation

/// The full per-user document exchanged with the sync server.
struct SyncDoc: Codable {
    var entries: [Entry]
    var tombstones: [Tombstone]
    var goals: [String: Goal]
    var goalsUpdatedAt: Date?

    func mergingLocal(_ local: SyncDoc, preferLocalGoals: Bool = false) -> SyncDoc {
        var deletedIDs = Set<UUID>()
        let deletions = (tombstones + local.tombstones).filter { deletedIDs.insert($0.id).inserted }
        var entryIDs = Set<UUID>()
        let combined = (entries + local.entries).filter {
            !deletedIDs.contains($0.id) && entryIDs.insert($0.id).inserted
        }
        let localIsNewer = (local.goalsUpdatedAt ?? .distantPast) > (goalsUpdatedAt ?? .distantPast)
        let source = preferLocalGoals || localIsNewer ? local : self
        return SyncDoc(entries: combined, tombstones: deletions, goals: source.goals,
                       goalsUpdatedAt: source.goalsUpdatedAt)
    }
}

/// Thin async client for the Mars Momentum sync server's /api endpoints.
struct SyncClient {
    let server: URL

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String
    }

    private struct TokenResponse: Decodable {
        let token: String
        let username: String
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    func register(username: String, password: String) async throws -> String {
        let response: TokenResponse = try await request(
            "api/register", body: Credentials(username: username, password: password))
        return response.token
    }

    func login(username: String, password: String) async throws -> String {
        let response: TokenResponse = try await request(
            "api/login", body: Credentials(username: username, password: password))
        return response.token
    }

    func logout(username: String, token: String) async {
        struct Empty: Encodable {}
        struct OK: Decodable { let ok: Bool }
        _ = try? await request("api/logout", body: Empty(), auth: (username, token)) as OK
    }

    func sync(username: String, token: String, doc: SyncDoc) async throws -> SyncDoc {
        try await request("api/sync", body: doc, auth: (username, token))
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        auth: (username: String, token: String)? = nil
    ) async throws -> Response {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth {
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            request.setValue(auth.username, forHTTPHeaderField: "X-Mars-User")
        }
        request.httpBody = try MarsJSON.makeEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError(message: "Can't reach \(server.host ?? "server") — \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Unexpected response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = (try? MarsJSON.makeDecoder().decode(ErrorResponse.self, from: data))?.error
            throw APIError(message: serverMessage ?? "Server error (\(http.statusCode))")
        }
        do {
            return try MarsJSON.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError(message: "Couldn't read the server's response")
        }
    }
}

import Foundation
import Combine

@MainActor
final class BlocklistStore: ObservableObject {
    @Published private(set) var blocklists: [Blocklist] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documents.appendingPathComponent("track-on-me-blocklists.json")
        }
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            load()
        } else {
            seedDefaults()
        }
    }

    // MARK: - Mutations

    func add(_ blocklist: Blocklist) {
        blocklists.append(blocklist)
        save()
    }

    func update(_ blocklist: Blocklist) {
        guard let index = blocklists.firstIndex(where: { $0.id == blocklist.id }) else { return }
        blocklists[index] = blocklist
        save()
    }

    func delete(_ blocklist: Blocklist) {
        blocklists.removeAll { $0.id == blocklist.id }
        save()
    }

    // MARK: - Queries

    func blocklist(withID id: UUID) -> Blocklist? {
        blocklists.first { $0.id == id }
    }

    /// Resolves ids to lists, silently dropping ids whose list has been deleted.
    func blocklists(withIDs ids: [UUID]) -> [Blocklist] {
        ids.compactMap(blocklist(withID:))
    }

    // MARK: - Persistence

    private func seedDefaults() {
        blocklists = [
            Blocklist(
                name: "Social Media",
                appIDs: ["instagram", "tiktok", "x", "facebook", "reddit", "snapchat"],
                websites: ["instagram.com", "tiktok.com", "x.com", "facebook.com", "reddit.com"],
                keywords: ["social"]
            ),
            Blocklist(
                name: "Video & Streaming",
                appIDs: ["youtube", "netflix", "twitch"],
                websites: ["youtube.com", "netflix.com", "twitch.tv"],
                keywords: ["streaming"]
            ),
        ]
        save()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            blocklists = try decoder.decode([Blocklist].self, from: data)
        } catch {
            // The file exists but can't be read: move it aside so the next save
            // can't silently overwrite the user's lists with an empty array.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(blocklists)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save blocklists: \(error)")
        }
    }
}

import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private enum TestError: Error { case unavailable }

private final class FakeSecrets: CoachSecretStorage {
    var values: [String: String] = [:]
    var failRead = false
    var failWrite = false
    var failDelete = false
    func read(account: String) throws -> String? {
        if failRead { throw TestError.unavailable }
        return values[account]
    }
    func write(_ value: String, account: String) throws {
        if failWrite { throw TestError.unavailable }
        values[account] = value
    }
    func remove(account: String) throws {
        if failDelete { throw TestError.unavailable }
        values.removeValue(forKey: account)
    }
}

@MainActor
private final class FakeShields: SessionShielding {
    var onAuthorizationChange: (() -> Void)?
    var blocksEverything = false
    func applyShields(for blocklists: [Blocklist], blockAllWebsites: Bool, websiteExceptions: [String]) {
        blocksEverything = blockAllWebsites
    }
    func clearShields() { blocksEverything = false }
}

private struct SilentNotifications: SessionNotifications {
    func scheduleEnd(for session: ActiveSession) {}
    func cancelEnd(id: UUID) {}
}

@main
private struct NativeRegressionTests {
    @MainActor static func main() throws {
        let suite = "mars-focus-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()
        let credentials = CoachCredentials(defaults: defaults, secrets: secrets)
        let gemini = "coach-api-key-gemini"
        let claude = "coach-api-key-claude"

        defaults.set("legacy-gemini", forKey: gemini)
        defaults.set("legacy-claude", forKey: claude)
        let coach = CoachStore(defaults: defaults, secrets: secrets)
        expect(coach.apiKey == "legacy-gemini", "Active provider must retain its migrated key")
        expect(secrets.values[claude] == "legacy-claude", "Inactive provider must also migrate")
        expect(defaults.object(forKey: gemini) == nil && defaults.object(forKey: claude) == nil,
               "Successful migration must remove plaintext preferences")
        coach.provider = .claude
        expect(coach.apiKey == "legacy-claude", "Provider switch must load its own key")
        coach.apiKey = "replacement"
        expect(secrets.values[claude] == "replacement" && secrets.values[gemini] == "legacy-gemini",
               "Editing one provider must not replace the other provider's key")

        defaults.set("stale-key", forKey: gemini)
        let preferred = try credentials.load(provider: "gemini")
        expect(preferred == "legacy-gemini", "Existing secure key must win over stale legacy state")
        expect(defaults.object(forKey: gemini) == nil, "Stale plaintext must be cleaned up")

        secrets.values.removeValue(forKey: gemini)
        defaults.set("keep-on-failure", forKey: gemini)
        secrets.failWrite = true
        do { _ = try credentials.load(provider: "gemini"); preconditionFailure("Expected storage failure") }
        catch TestError.unavailable {}
        expect(defaults.string(forKey: gemini) == "keep-on-failure", "Failed migration must preserve the only key")
        secrets.failWrite = false
        secrets.failRead = true
        do { _ = try credentials.load(provider: "gemini"); preconditionFailure("Expected read failure") }
        catch TestError.unavailable {}
        expect(defaults.string(forKey: gemini) == "keep-on-failure", "Unavailable Keychain must not erase preferences")
        secrets.failRead = false
        _ = try credentials.load(provider: "gemini")
        secrets.failWrite = true
        coach.apiKey = "unsaved-replacement"
        expect(coach.keyStorageError != nil && secrets.values[claude] == "replacement",
               "Failed replacement must be visible and preserve the saved key")
        secrets.failWrite = false
        coach.apiKey = ""
        expect(secrets.values[claude] == nil, "Clearing a key must remove it from secure storage")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mars-focus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lists = BlocklistStore(fileURL: root.appendingPathComponent("lists.json"))
        let shields = FakeShields()
        let store = SessionStore(blocklistStore: lists, screenTime: shields,
                                 fileURL: root.appendingPathComponent("sessions.json"), notifications: SilentNotifications())
        store.scheduleSession(startAt: .now.addingTimeInterval(-1), minutes: 30,
                              blocklistIDs: [], isLocked: false, blocksEverything: true)
        store.tick()
        expect(store.scheduled.isEmpty && store.active?.isBlockingEverything == true && shields.blocksEverything,
               "Due Everything sessions must activate even with no blocklists")
        store.endActiveSessionEarly()
        store.scheduleSession(startAt: .now.addingTimeInterval(-1), minutes: 30,
                              blocklistIDs: [UUID()], isLocked: true)
        store.tick()
        expect(store.scheduled.isEmpty && store.active == nil,
               "Ordinary sessions whose lists were deleted must still be discarded")
        store.scheduleSession(startAt: .now.addingTimeInterval(-3600), minutes: 30,
                              blocklistIDs: [], isLocked: true, blocksEverything: true)
        store.tick()
        expect(store.scheduled.isEmpty && store.active == nil, "Expired Everything windows must not start")
        print("PASS: credential migration, storage failures, provider isolation, and session scheduling")
    }
}

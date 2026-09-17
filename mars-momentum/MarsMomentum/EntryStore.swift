import Foundation

struct SyncAccount: Equatable {
    var server: URL
    var username: String
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
}

@MainActor
final class EntryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var goals: [TrackerCategory: Goal] = [:]
    @Published private(set) var account: SyncAccount?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var syncStatus: SyncStatus = .idle

    private(set) var tombstones: [Tombstone] = []
    private(set) var goalsUpdatedAt: Date?
    private var syncTask: Task<Void, Never>?
    private var sessionGeneration = 0
    private var mutationRevision = 0

    private let calendar = Calendar.current
    private let fileURL: URL
    private var goalsFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("mars-tracking-goals.json")
    }
    private var tombstonesFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("mars-tracking-tombstones.json")
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            #if os(macOS)
            // Unsandboxed macOS resolves .documentDirectory to the user's real
            // ~/Documents — app data belongs in Application Support instead.
            // Keep the original directory so the rename retains existing records.
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mars Tracking", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("mars-tracking-entries.json")
            #else
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documents.appendingPathComponent("mars-tracking-entries.json")
            #endif
        }
        load()
        loadGoals()
        loadTombstones()
        restoreAccount()
    }

    // MARK: - Mutations

    func add(category: TrackerCategory, kind: ValueKind, amount: Double, on day: Date) {
        guard amount.isFinite, amount > 0 else { return }
        entries.append(Entry(date: timestamp(for: day), category: category, kind: kind, amount: amount))
        save()
        scheduleSync()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        // Tombstone so the deletion survives the union-based sync merge.
        tombstones.append(Tombstone(id: entry.id, deletedAt: .now))
        save()
        saveTombstones()
        scheduleSync()
    }

    func updateGoals(_ newGoals: [TrackerCategory: Goal]) {
        goals = newGoals.filter { $0.value.amount.isFinite && $0.value.amount > 0 }
        goalsUpdatedAt = .now
        saveGoals()
        scheduleSync()
    }

    // MARK: - Goal progress

    /// Achieved-vs-target for an activity's daily goal (nil when no goal is set).
    /// Only entries matching the goal's kind count toward it.
    func goalProgress(for category: TrackerCategory, on day: Date) -> (achieved: Double, goal: Goal)? {
        guard category != .weight, let goal = goals[category] else { return nil }
        let achieved = entries(on: day, category: category)
            .filter { $0.kind == goal.kind }
            .reduce(0) { $0 + $1.amount }
        return (achieved, goal)
    }

    /// Number of days on which the category's daily goal was fully met.
    func goalsMetCount(for category: TrackerCategory) -> Int {
        guard category != .weight, let goal = goals[category] else { return 0 }
        var byDay: [Date: Double] = [:]
        for entry in entries where entry.category == category && entry.kind == goal.kind {
            byDay[calendar.startOfDay(for: entry.date), default: 0] += entry.amount
        }
        return byDay.values.filter { $0 >= goal.amount - 1e-9 }.count
    }

    // MARK: - Queries

    func entries(on day: Date) -> [Entry] {
        entries
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    func entries(on day: Date, category: TrackerCategory) -> [Entry] {
        entries(on: day).filter { $0.category == category }
    }

    func categoriesLogged(on day: Date) -> [TrackerCategory] {
        let logged = Set(entries(on: day).map(\.category))
        return TrackerCategory.allCases.filter { logged.contains($0) }
    }

    /// Short summary shown on a category card, e.g. "1h 30m", "72.5 kg", "1h · ×3".
    func summary(for category: TrackerCategory, on day: Date) -> String? {
        let dayEntries = entries(on: day, category: category)
        guard !dayEntries.isEmpty else { return nil }
        if category == .weight, let last = dayEntries.last {
            return last.formattedAmount
        }
        let duration = dayEntries.filter { $0.kind == .duration }.reduce(0) { $0 + $1.amount }
        let number = dayEntries.filter { $0.kind == .number }.reduce(0) { $0 + $1.amount }
        var parts: [String] = []
        if duration > 0 { parts.append(Format.duration(duration)) }
        if number > 0 { parts.append("×\(Format.number(number))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Heatmap

    /// One pass over all entries → per-day (start-of-day keyed) intensity levels.
    func dayLevels(filter: TrackerCategory?) -> [Date: Int] {
        var buckets: [Date: [Entry]] = [:]
        for entry in entries where filter == nil || entry.category == filter {
            buckets[calendar.startOfDay(for: entry.date), default: []].append(entry)
        }
        return buckets.mapValues { level(for: $0, filter: filter) }
    }

    private func level(for dayEntries: [Entry], filter: TrackerCategory?) -> Int {
        guard !dayEntries.isEmpty else { return 0 }
        guard let filter else {
            // "All" view: intensity = how many categories were logged that day.
            return min(4, Set(dayEntries.map(\.category)).count)
        }
        // A weigh-in either happened or it didn't — full shade, no gradations.
        if filter == .weight { return 4 }
        if let goal = goals[filter] {
            // Goal-aware intensity: partial shades are fractions of the daily
            // goal, full wine means the goal was met (LeetCode "solved" style).
            let achieved = dayEntries.filter { $0.kind == goal.kind }.reduce(0.0) { $0 + $1.amount }
            let fraction = achieved / goal.amount
            // Small tolerance so 0.1 + 0.7 counts against a 0.8 goal despite IEEE sums.
            if fraction >= 1 - 1e-9 { return 4 }
            return max(1, min(3, Int((fraction * 3).rounded(.up))))
        }
        let minutes = dayEntries.filter { $0.kind == .duration }.reduce(0.0) { $0 + $1.amount } / 60
        // Count entries score one point each regardless of magnitude, so a
        // single "5" (km, reps, ...) can't max out the heatmap on its own.
        let countEntries = dayEntries.filter { $0.kind == .number }.count
        let score = (minutes / 30).rounded(.up) + Double(countEntries)
        // Clamp before converting: a valid, very large synced duration (or an
        // overflowing sum) must not trap while drawing the calendar.
        return Int(max(1, min(4, score)))
    }

    /// Compact per-day value for the calendar's Numbers mode, e.g. "1.5h", "×3",
    /// "72.1", or the entry count when no category filter is active.
    func calendarValue(on day: Date, filter: TrackerCategory?) -> String? {
        guard let filter else {
            let count = entries(on: day).count
            return count > 0 ? "\(count)" : nil
        }
        let dayEntries = entries(on: day, category: filter)
        guard !dayEntries.isEmpty else { return nil }
        if filter == .weight, let last = dayEntries.last {
            return Format.number(last.amount)
        }
        let duration = dayEntries.filter { $0.kind == .duration }.reduce(0.0) { $0 + $1.amount }
        if duration > 0 { return Format.shortDuration(duration) }
        let number = dayEntries.filter { $0.kind == .number }.reduce(0.0) { $0 + $1.amount }
        return number > 0 ? "×\(Format.number(number))" : nil
    }

    // MARK: - Stats

    func isActive(on day: Date, filter: TrackerCategory?) -> Bool {
        if let filter { return !entries(on: day, category: filter).isEmpty }
        return !entries(on: day).isEmpty
    }

    /// Consecutive active days ending today (or yesterday, if today has nothing yet).
    func currentStreak(filter: TrackerCategory?, asOf today: Date = .now) -> Int {
        var day = calendar.startOfDay(for: today)
        if !isActive(on: day, filter: filter) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while isActive(on: day, filter: filter) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: previous)
        }
        return streak
    }

    func bestStreak(filter: TrackerCategory?) -> Int {
        let days = activeDays(filter: filter)
        var best = 0
        for day in days {
            // Re-apply startOfDay after every byAdding step: around DST jumps that
            // skip midnight, byAdding carries the shifted wall time onto later days,
            // which would break exact-Date membership against startOfDay-keyed sets.
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day),
                  !days.contains(calendar.startOfDay(for: previous)) else { continue }
            var length = 1
            var cursor = day
            while let next = calendar.date(byAdding: .day, value: 1, to: cursor).map(calendar.startOfDay(for:)),
                  days.contains(next) {
                length += 1
                cursor = next
            }
            best = max(best, length)
        }
        return best
    }

    func activeDayCount(filter: TrackerCategory?) -> Int {
        activeDays(filter: filter).count
    }

    func totalSummary(filter: TrackerCategory?) -> String {
        let relevant = entries.filter { filter == nil || $0.category == filter }
        if filter == .weight {
            // Retro-logged entries share the same noon timestamp; prefer the most
            // recently *added* one so this agrees with the day summary.
            guard let latestDate = relevant.map(\.date).max(),
                  let latest = relevant.last(where: { $0.date == latestDate }) else { return "—" }
            return latest.formattedAmount
        }
        if filter == nil { return "\(relevant.count)" }
        let duration = relevant.filter { $0.kind == .duration }.reduce(0) { $0 + $1.amount }
        let number = relevant.filter { $0.kind == .number }.reduce(0) { $0 + $1.amount }
        var parts: [String] = []
        if duration > 0 { parts.append(Format.duration(duration)) }
        if number > 0 { parts.append("×\(Format.number(number))") }
        return parts.isEmpty ? "0" : parts.joined(separator: " · ")
    }

    private func activeDays(filter: TrackerCategory?) -> Set<Date> {
        Set(entries
            .filter { filter == nil || $0.category == filter }
            .map { calendar.startOfDay(for: $0.date) })
    }

    // MARK: - Persistence

    private func timestamp(for day: Date) -> Date {
        if calendar.isDateInToday(day) { return .now }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try MarsJSON.makeDecoder().decode([Entry].self, from: data)
        } catch {
            // The file exists but can't be read: move it aside so the next save
            // can't silently overwrite the whole history with an empty array.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        do {
            let data = try MarsJSON.makeEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save entries: \(error)")
        }
    }

    private func loadTombstones() {
        guard let data = try? Data(contentsOf: tombstonesFileURL),
              let decoded = try? MarsJSON.makeDecoder().decode([Tombstone].self, from: data) else { return }
        tombstones = decoded
    }

    private func saveTombstones() {
        if let data = try? MarsJSON.makeEncoder().encode(tombstones) {
            try? data.write(to: tombstonesFileURL, options: .atomic)
        }
    }

    /// Wrapper that swallows per-record decode failures so one bad goal
    /// (e.g. written by a newer app version) can't wipe all the others.
    private struct FailableGoal: Decodable {
        let goal: Goal?
        init(from decoder: Decoder) throws { goal = try? Goal(from: decoder) }
    }

    // MARK: - Account & sync

    private enum SyncDefaults {
        static let server = "syncServer"
        static let username = "syncUsername"
        static let lastSynced = "syncLastSynced"
        static let tokenKey = "sync-token"
    }

    private func restoreAccount() {
        guard let serverText = UserDefaults.standard.string(forKey: SyncDefaults.server),
              let server = URL(string: serverText),
              let username = UserDefaults.standard.string(forKey: SyncDefaults.username),
              Keychain.get(SyncDefaults.tokenKey) != nil else { return }
        account = SyncAccount(server: server, username: username)
        let stamp = UserDefaults.standard.double(forKey: SyncDefaults.lastSynced)
        if stamp > 0 { lastSyncedAt = Date(timeIntervalSince1970: stamp) }
    }

    /// Signs in (or registers) and runs a first sync. Returns an error message, or nil on success.
    func signIn(serverText: String, username: String, password: String, creating: Bool) async -> String? {
        let trimmed = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = URL(string: trimmed),
              let scheme = server.scheme?.lowercased(), ["http", "https"].contains(scheme), server.host != nil,
              server.user == nil, server.password == nil, server.query == nil, server.fragment == nil else {
            return "Enter a server URL like https://example.com or http://localhost:8473"
        }
        let name = username.lowercased().trimmingCharacters(in: .whitespaces)
        let client = SyncClient(server: server)
        sessionGeneration += 1
        let generation = sessionGeneration
        syncStatus = .idle
        do {
            let token = creating
                ? try await client.register(username: name, password: password)
                : try await client.login(username: name, password: password)
            guard generation == sessionGeneration else { return "Sign-in was cancelled" }
            try Keychain.set(token, for: SyncDefaults.tokenKey)
            UserDefaults.standard.set(server.absoluteString, forKey: SyncDefaults.server)
            UserDefaults.standard.set(name, forKey: SyncDefaults.username)
            account = SyncAccount(server: server, username: name)
            await syncNow()
            if case .error(let message) = syncStatus { return message }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() async {
        let previous = account
        let token = Keychain.get(SyncDefaults.tokenKey)
        sessionGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        Keychain.delete(SyncDefaults.tokenKey)
        UserDefaults.standard.removeObject(forKey: SyncDefaults.server)
        UserDefaults.standard.removeObject(forKey: SyncDefaults.username)
        UserDefaults.standard.removeObject(forKey: SyncDefaults.lastSynced)
        account = nil
        lastSyncedAt = nil
        syncStatus = .idle
        // Local data stays on the device; signing out only stops syncing.
        if let previous, let token {
            await SyncClient(server: previous.server).logout(username: previous.username, token: token)
        }
    }

    func syncNow() async {
        guard let account, let token = Keychain.get(SyncDefaults.tokenKey) else { return }
        if syncStatus == .syncing { return }
        let generation = sessionGeneration
        syncStatus = .syncing
        do {
            while generation == sessionGeneration {
                let revision = mutationRevision
                let sent = currentDoc()
                let response = try await SyncClient(server: account.server)
                    .sync(username: account.username, token: token, doc: sent)
                guard generation == sessionGeneration else { return }
                let current = currentDoc()
                let goalsChanged = current.goals != sent.goals || current.goalsUpdatedAt != sent.goalsUpdatedAt
                apply(response.mergingLocal(current, preferLocalGoals: goalsChanged))
                if mutationRevision == revision {
                    lastSyncedAt = .now
                    UserDefaults.standard.set(lastSyncedAt!.timeIntervalSince1970, forKey: SyncDefaults.lastSynced)
                    syncStatus = .idle
                    return
                }
            }
        } catch {
            guard generation == sessionGeneration else { return }
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func currentDoc() -> SyncDoc {
        SyncDoc(
            entries: entries,
            tombstones: tombstones,
            goals: Dictionary(uniqueKeysWithValues: goals.map { ($0.key.rawValue, $0.value) }),
            goalsUpdatedAt: goalsUpdatedAt
        )
    }

    private func apply(_ merged: SyncDoc) {
        entries = merged.entries
        tombstones = merged.tombstones
        var mergedGoals: [TrackerCategory: Goal] = [:]
        for (key, goal) in merged.goals {
            if let category = TrackerCategory(rawValue: key), goal.amount.isFinite, goal.amount > 0 {
                mergedGoals[category] = goal
            }
        }
        goals = mergedGoals
        goalsUpdatedAt = merged.goalsUpdatedAt
        save()
        saveTombstones()
        saveGoals()
    }

    /// Debounced auto-sync after local mutations.
    private func scheduleSync() {
        mutationRevision += 1
        guard account != nil else { return }
        // The in-flight loop will send another document when it sees this edit.
        guard syncStatus != .syncing else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncTask = nil
            await self?.syncNow()
        }
    }

    private struct GoalsFile: Codable {
        var goals: [String: Goal]
        var updatedAt: Date?
    }

    private struct FailableGoalsFile: Decodable {
        let goals: [String: FailableGoal]?
        let updatedAt: Date?
    }

    private func loadGoals() {
        guard FileManager.default.fileExists(atPath: goalsFileURL.path) else { return }
        guard let data = try? Data(contentsOf: goalsFileURL) else { return }
        let decoder = MarsJSON.makeDecoder()
        var rawGoals: [String: FailableGoal]?
        if let file = try? decoder.decode(FailableGoalsFile.self, from: data), file.goals != nil {
            rawGoals = file.goals
            goalsUpdatedAt = file.updatedAt
        } else if let legacy = try? decoder.decode([String: FailableGoal].self, from: data) {
            // Pre-sync schema: a bare category → goal dictionary.
            rawGoals = legacy
        } else {
            // Whole file unreadable: set it aside like the entries loader does.
            let backup = goalsFileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: goalsFileURL, to: backup)
            return
        }
        var loaded: [TrackerCategory: Goal] = [:]
        for (key, failable) in rawGoals ?? [:] {
            if let category = TrackerCategory(rawValue: key), let goal = failable.goal, goal.amount > 0 {
                loaded[category] = goal
            }
        }
        goals = loaded
    }

    private func saveGoals() {
        let raw = Dictionary(uniqueKeysWithValues: goals.map { ($0.key.rawValue, $0.value) })
        if let data = try? MarsJSON.makeEncoder().encode(GoalsFile(goals: raw, updatedAt: goalsUpdatedAt)) {
            try? data.write(to: goalsFileURL, options: .atomic)
        }
    }
}

#if DEBUG
extension EntryStore {
    /// Populates a few months of deterministic sample data for UI screenshots.
    func seedDemoData() {
        guard entries.isEmpty else { return }
        var generator = SeededGenerator(seed: 42)
        var seeded: [Entry] = []
        for offset in 0..<120 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now)) else { continue }
            if Double.random(in: 0...1, using: &generator) < 0.75 {
                seeded.append(Entry(date: day.addingTimeInterval(9 * 3600), category: .study, kind: .duration,
                                    amount: Double(Int.random(in: 2...10, using: &generator)) * 15 * 60))
            }
            if Double.random(in: 0...1, using: &generator) < 0.5 {
                seeded.append(Entry(date: day.addingTimeInterval(18 * 3600), category: .gym, kind: .duration,
                                    amount: Double(Int.random(in: 3...6, using: &generator)) * 15 * 60))
            }
            if Double.random(in: 0...1, using: &generator) < 0.4 {
                seeded.append(Entry(date: day.addingTimeInterval(7 * 3600), category: .cardio, kind: .number,
                                    amount: Double(Int.random(in: 1...3, using: &generator))))
            }
            if Double.random(in: 0...1, using: &generator) < 0.3 {
                seeded.append(Entry(date: day.addingTimeInterval(8 * 3600), category: .weight, kind: .number,
                                    amount: 72 + Double(Int.random(in: -20...20, using: &generator)) / 10))
            }
        }
        entries = seeded
        save()
        if goals.isEmpty {
            updateGoals([
                .study: Goal(kind: .duration, amount: 2 * 3600),
                .gym: Goal(kind: .duration, amount: 45 * 60),
                .cardio: Goal(kind: .number, amount: 2),
                .weight: Goal(kind: .number, amount: 70),
            ])
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif

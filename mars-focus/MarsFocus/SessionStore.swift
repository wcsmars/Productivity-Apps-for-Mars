import Foundation
import Combine

@MainActor
protocol SessionShielding: AnyObject {
    var onAuthorizationChange: (() -> Void)? { get set }
    func applyShields(for blocklists: [Blocklist], blockAllWebsites: Bool, websiteExceptions: [String])
    func clearShields()
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var active: ActiveSession?
    @Published private(set) var scheduled: [ScheduledSession] = []
    @Published private(set) var rules: [ScheduleRule] = []
    @Published private(set) var history: [SessionRecord] = []
    /// Wall clock, republished every second while a session runs (drives the countdown).
    @Published private(set) var now = Date.now

    /// Domains that stay reachable during "block all websites" sessions.
    @Published private(set) var websiteExceptions: [String] = []

    private(set) var lastUsedBlocklistIDs: [UUID] = []
    /// Occurrence key → window end, so a recurring window fires at most once
    /// (ending a session early must not restart it a second later).
    private var triggeredOccurrences: [String: Date] = [:]

    private let calendar = Calendar.current
    private let fileURL: URL
    private let blocklistStore: BlocklistStore
    private let screenTime: any SessionShielding
    private let notifications: any SessionNotifications

    init(blocklistStore: BlocklistStore, screenTime: any SessionShielding, fileURL: URL? = nil,
         notifications: any SessionNotifications = LocalSessionNotifications()) {
        self.blocklistStore = blocklistStore
        self.screenTime = screenTime
        self.notifications = notifications
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documents.appendingPathComponent("track-on-me-sessions.json")
        }
        load()
        tick() // catch up on anything that came due while the app was closed
        // Re-shield a session that was restored from disk and is still running,
        // and again whenever authorization flips (granted mid-session, or
        // resolved late after a cold launch).
        refreshShields()
        screenTime.onAuthorizationChange = { [weak self] in
            self?.refreshShields()
        }
    }

    /// Re-applies OS shields to match the current blocklists — call after
    /// blocklist edits, exception edits, or an authorization change mid-session.
    func refreshShields() {
        guard let session = active else { return }
        screenTime.applyShields(for: blocklistStore.blocklists(withIDs: session.blocklistIDs),
                                blockAllWebsites: session.isBlockingEverything,
                                websiteExceptions: websiteExceptions)
    }

    func setWebsiteExceptions(_ domains: [String]) {
        websiteExceptions = domains
        save()
        refreshShields()
    }

    // MARK: - Clock

    /// Called once a second while the app is in the foreground, and whenever it
    /// returns to the foreground: completes overdue sessions and starts due ones.
    func tick() {
        let current = Date.now
        // Publish every second only while a countdown is running; once a
        // minute otherwise, so idle tabs aren't re-rendered 60x more than
        // their content can change.
        if active != nil || calendar.component(.second, from: current) == 0 {
            now = current
        }
        var dirty = false

        // Complete a session whose time is up.
        if let session = active, session.endsAt <= current {
            record(session, endedAt: session.endsAt, endedEarly: false)
            active = nil
            screenTime.clearShields()
            dirty = true
        }

        // Drop queued sessions whose whole window passed while the app was closed,
        // and due ones whose blocklists were all deleted — a locked shell that
        // blocks nothing must never start.
        let dead = scheduled.filter {
            $0.endAt <= current ||
            ($0.startAt <= current && !$0.isBlockingEverything &&
             blocklistStore.blocklists(withIDs: $0.blocklistIDs).isEmpty)
        }
        if !dead.isEmpty {
            scheduled.removeAll { dead.contains($0) }
            dirty = true
        }

        // Start the earliest queued session that is due. Focus is counted from
        // "now", never backdated: time before activation was either unobserved
        // (app closed) or already recorded by the session that blocked this one.
        if active == nil,
           let due = scheduled.filter({ $0.startAt <= current }).min(by: { $0.startAt < $1.startAt }) {
            scheduled.removeAll { $0.id == due.id }
            activate(blocklistIDs: due.blocklistIDs, startedAt: current, endsAt: due.endAt,
                     isLocked: due.isLocked, scheduleName: due.name,
                     blocksEverything: due.isBlockingEverything)
            dirty = true
        }

        // Start a recurring schedule whose window contains "now".
        if active == nil, checkRules(at: current) {
            dirty = true
        }

        if dirty { save() }
    }

    private func checkRules(at current: Date) -> Bool {
        for rule in rules where rule.isEnabled {
            guard let occurrence = rule.occurrence(containing: current, calendar: calendar) else { continue }
            let key = occurrenceKey(rule: rule, start: occurrence.start)
            guard triggeredOccurrences[key] == nil else { continue }
            // A rule whose blocklists were all deleted stays dormant instead of
            // trapping the user in a (possibly locked) session that blocks nothing.
            guard !blocklistStore.blocklists(withIDs: rule.blocklistIDs).isEmpty else { continue }
            triggeredOccurrences[key] = occurrence.end
            pruneTriggeredOccurrences(asOf: current)
            // startedAt is "now", not the window start — see the comment above.
            activate(blocklistIDs: rule.blocklistIDs, startedAt: current, endsAt: occurrence.end,
                     isLocked: rule.isLocked, scheduleName: rule.name)
            return true
        }
        return false
    }

    private func occurrenceKey(rule: ScheduleRule, start: Date) -> String {
        "\(rule.id.uuidString)|\(Int(start.timeIntervalSince1970))"
    }

    private func pruneTriggeredOccurrences(asOf date: Date) {
        let cutoff = date.addingTimeInterval(-48 * 3600)
        triggeredOccurrences = triggeredOccurrences.filter { $0.value > cutoff }
    }

    // MARK: - Starting & ending sessions

    /// Sessions run from 1 minute up to 24 hours.
    static let maxSessionMinutes = 24 * 60

    func startSession(blocklistIDs: [UUID], minutes: Int, isLocked: Bool,
                      blocksEverything: Bool = false) {
        guard active == nil, minutes > 0 else { return }
        let clamped = min(minutes, Self.maxSessionMinutes)
        let start = Date.now
        guard let end = calendar.date(byAdding: .minute, value: clamped, to: start) else { return }
        if !blocklistIDs.isEmpty { lastUsedBlocklistIDs = blocklistIDs }
        activate(blocklistIDs: blocklistIDs, startedAt: start, endsAt: end,
                 isLocked: isLocked, scheduleName: nil, blocksEverything: blocksEverything)
        save()
    }

    func scheduleSession(startAt: Date, minutes: Int, blocklistIDs: [UUID], isLocked: Bool,
                         blocksEverything: Bool = false) {
        guard minutes > 0 else { return }
        if !blocklistIDs.isEmpty { lastUsedBlocklistIDs = blocklistIDs }
        scheduled.append(ScheduledSession(startAt: startAt, minutes: min(minutes, Self.maxSessionMinutes),
                                          blocklistIDs: blocklistIDs, isLocked: isLocked,
                                          blocksEverything: blocksEverything ? true : nil))
        scheduled.sort { $0.startAt < $1.startAt }
        save()
    }

    /// Pomodoro: the first work round starts now; later rounds are queued
    /// sessions, so breaks are simply the unblocked gaps between them and the
    /// remaining rounds show up (and can be cancelled) like any queued session.
    func startPomodoro(blocklistIDs: [UUID], workMinutes: Int, breakMinutes: Int,
                       rounds: Int, isLocked: Bool) {
        guard active == nil, workMinutes > 0, breakMinutes >= 0, rounds >= 1 else { return }
        if !blocklistIDs.isEmpty { lastUsedBlocklistIDs = blocklistIDs }
        let start = Date.now
        guard let firstEnd = calendar.date(byAdding: .minute, value: workMinutes, to: start) else { return }
        activate(blocklistIDs: blocklistIDs, startedAt: start, endsAt: firstEnd, isLocked: isLocked,
                 scheduleName: rounds > 1 ? "Pomodoro 1 of \(rounds)" : "Pomodoro")
        let cycle = TimeInterval((workMinutes + breakMinutes) * 60)
        for round in 1..<rounds {
            scheduled.append(ScheduledSession(startAt: start.addingTimeInterval(cycle * Double(round)),
                                              minutes: workMinutes, blocklistIDs: blocklistIDs,
                                              isLocked: isLocked,
                                              name: "Pomodoro \(round + 1) of \(rounds)"))
        }
        scheduled.sort { $0.startAt < $1.startAt }
        save()
    }

    func cancelScheduled(_ session: ScheduledSession) {
        scheduled.removeAll { $0.id == session.id }
        save()
    }

    func endActiveSessionEarly() {
        guard let session = active, !session.isLocked else { return }
        record(session, endedAt: Date.now, endedEarly: true)
        active = nil
        screenTime.clearShields()
        cancelEndNotification(id: session.id)
        save()
    }

    func extendActiveSession(byMinutes minutes: Int) {
        guard var session = active else { return }
        session.endsAt = session.endsAt.addingTimeInterval(TimeInterval(minutes * 60))
        active = session
        cancelEndNotification(id: session.id)
        scheduleEndNotification(for: session)
        save()
    }

    private func activate(blocklistIDs: [UUID], startedAt: Date, endsAt: Date,
                          isLocked: Bool, scheduleName: String?, blocksEverything: Bool = false) {
        let lists = blocklistStore.blocklists(withIDs: blocklistIDs)
        let names = blocksEverything ? ["All websites"] : lists.map(\.name)
        let session = ActiveSession(id: UUID(), startedAt: startedAt, endsAt: endsAt,
                                    blocklistIDs: blocklistIDs, blocklistNames: names,
                                    isLocked: isLocked, scheduleName: scheduleName,
                                    blocksEverything: blocksEverything ? true : nil)
        active = session
        now = Date.now
        screenTime.applyShields(for: lists, blockAllWebsites: blocksEverything,
                                websiteExceptions: websiteExceptions)
        scheduleEndNotification(for: session)
    }

    private func record(_ session: ActiveSession, endedAt: Date, endedEarly: Bool) {
        let planned = Int((session.plannedDuration / 60).rounded())
        history.append(SessionRecord(startedAt: session.startedAt, endedAt: endedAt,
                                     plannedMinutes: planned, blocklistNames: session.blocklistNames,
                                     scheduleName: session.scheduleName, endedEarly: endedEarly))
    }

    /// Blocklists that can't be edited right now because a locked session is using them.
    var lockedBlocklistIDs: Set<UUID> {
        guard let session = active, session.isLocked else { return [] }
        return Set(session.blocklistIDs)
    }

    // MARK: - Recurring schedule CRUD

    func add(_ rule: ScheduleRule) {
        rules.append(rule)
        save()
        tick() // an enabled rule whose window contains "now" starts immediately
    }

    func update(_ rule: ScheduleRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
        tick()
    }

    func delete(_ rule: ScheduleRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func setRule(_ rule: ScheduleRule, enabled: Bool) {
        var updated = rule
        updated.isEnabled = enabled
        update(updated)
    }

    // MARK: - Upcoming

    /// The soonest queued or recurring session still ahead of `date`.
    func nextUpcoming(after date: Date) -> UpcomingSession? {
        var candidates: [UpcomingSession] = scheduled.map {
            UpcomingSession(title: $0.name ?? "Scheduled session", start: $0.startAt, end: $0.endAt)
        }
        for rule in rules {
            // A rule whose blocklists were all deleted stays dormant
            // (checkRules skips it), so don't advertise it either.
            guard !blocklistStore.blocklists(withIDs: rule.blocklistIDs).isEmpty else { continue }
            guard var occurrence = rule.nextOccurrence(after: date, calendar: calendar) else { continue }
            // A window that already fired (even if its session ended early) can
            // never start again — advertise the following occurrence instead.
            if triggeredOccurrences[occurrenceKey(rule: rule, start: occurrence.start)] != nil {
                guard let following = rule.nextOccurrence(after: occurrence.end, calendar: calendar) else { continue }
                occurrence = following
            }
            candidates.append(UpcomingSession(title: rule.name, start: occurrence.start, end: occurrence.end))
        }
        return candidates.min { $0.start < $1.start }
    }

    // MARK: - Calendar

    /// Finished sessions that overlap the given day (a session crossing
    /// midnight shows on both days, matching the heatmap/dot attribution).
    func sessions(on day: Date) -> [SessionRecord] {
        let dayStart = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
                .map(calendar.startOfDay(for:)) else { return [] }
        return history
            .filter { $0.startedAt < nextDay && $0.endedAt > dayStart }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Planned block windows overlapping the given day: queued one-off
    /// sessions plus enabled recurring rules. Past days return nothing —
    /// what actually happened lives in the session history.
    func plannedSlots(on day: Date) -> [UpcomingSession] {
        let dayStart = calendar.startOfDay(for: day)
        guard dayStart >= calendar.startOfDay(for: .now),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
                .map(calendar.startOfDay(for:)) else { return [] }
        var slots: [UpcomingSession] = scheduled
            .filter { $0.startAt < nextDay && $0.endAt > dayStart }
            .map { UpcomingSession(title: $0.name ?? "Scheduled session", start: $0.startAt, end: $0.endAt) }
        for rule in rules where rule.isEnabled {
            // Dormant rules (all blocklists deleted) never fire — don't draw them.
            guard !blocklistStore.blocklists(withIDs: rule.blocklistIDs).isEmpty else { continue }
            // Offset -1 catches the after-midnight tail of overnight windows.
            for offset in [0, -1] {
                guard let start = calendar.date(byAdding: .day, value: offset, to: dayStart)
                        .map(calendar.startOfDay(for:)),
                      rule.weekdays.contains(calendar.component(.weekday, from: start)),
                      let occurrence = rule.occurrence(startingOn: start, calendar: calendar),
                      occurrence.start < nextDay, occurrence.end > dayStart else { continue }
                slots.append(UpcomingSession(title: rule.name, start: occurrence.start, end: occurrence.end))
            }
        }
        return slots.sorted { $0.start < $1.start }
    }

    func hasPlannedSlot(on day: Date) -> Bool {
        !plannedSlots(on: day).isEmpty
    }

    // MARK: - Coach

    /// Compact plain-text stats summary handed to the AI coach as context.
    func coachContext() -> String {
        let minutes = dayMinutes()
        let today = calendar.startOfDay(for: .now)
        let recent = (0..<14).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let dayStart = calendar.startOfDay(for: day)
            let focused = Int(minutes[dayStart] ?? 0)
            return "\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(focused) min"
        }.joined(separator: "\n")

        var lines: [String] = []
        lines.append("Current streak: \(currentStreak()) days; best streak: \(bestStreak()) days.")
        lines.append("Sessions completed: \(completedSessionCount); ended early: \(history.filter(\.endedEarly).count).")
        lines.append("Total focus time: \(Format.duration(totalFocusTime())).")
        if let session = active {
            lines.append("A session is running right now, ending at \(session.endsAt.formatted(date: .omitted, time: .shortened)).")
        }
        for rule in rules {
            lines.append("Schedule \"\(rule.name)\": \(rule.daysSummary(calendar: calendar)), \(rule.timeSummary(calendar: calendar)) (\(rule.isEnabled ? "enabled" : "disabled")\(rule.isLocked ? ", locked" : "")).")
        }
        let listNames = blocklistStore.blocklists.map(\.name).joined(separator: ", ")
        if !listNames.isEmpty { lines.append("Blocklists: \(listNames).") }
        lines.append("Focus minutes per day, most recent first:\n\(recent)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Stats

    /// Focused minutes per start-of-day, splitting sessions that cross midnight
    /// and including the elapsed part of the running session.
    func dayMinutes() -> [Date: Double] {
        var minutes: [Date: Double] = [:]
        func addSpan(from start: Date, to end: Date) {
            var cursor = start
            while cursor < end {
                let dayStart = calendar.startOfDay(for: cursor)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                let boundary = calendar.startOfDay(for: nextDay)
                let segmentEnd = min(boundary, end)
                guard segmentEnd > cursor else { break }
                minutes[dayStart, default: 0] += segmentEnd.timeIntervalSince(cursor) / 60
                cursor = segmentEnd
            }
        }
        for item in history { addSpan(from: item.startedAt, to: item.endedAt) }
        if let session = active { addSpan(from: session.startedAt, to: min(Date.now, session.endsAt)) }
        return minutes
    }

    /// Per-day heatmap intensity: every started half hour of focus is one level, capped at 4.
    func dayLevels() -> [Date: Int] {
        dayMinutes().mapValues { value in
            value <= 0 ? 0 : max(1, min(4, Int((value / 30).rounded(.up))))
        }
    }

    /// Consecutive focused days ending today (or yesterday, if today has nothing yet).
    func currentStreak(asOf today: Date = .now) -> Int {
        let days = activeDays()
        var day = calendar.startOfDay(for: today)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = calendar.startOfDay(for: yesterday)
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: previous)
        }
        return streak
    }

    func bestStreak() -> Int {
        let days = activeDays()
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

    func totalFocusTime() -> TimeInterval {
        var total = history.reduce(0) { $0 + max(0, $1.duration) }
        if let session = active {
            // max(0, ...) so a device clock set backwards can't deflate the total.
            total += max(0, min(Date.now, session.endsAt).timeIntervalSince(session.startedAt))
        }
        return total
    }

    var completedSessionCount: Int {
        history.filter { !$0.endedEarly }.count
    }

    private func activeDays() -> Set<Date> {
        Set(dayMinutes().filter { $0.value > 0 }.keys)
    }

    // MARK: - Notifications

    private func scheduleEndNotification(for session: ActiveSession) {
        notifications.scheduleEnd(for: session)
    }

    private func cancelEndNotification(id: UUID) {
        notifications.cancelEnd(id: id)
    }

    // MARK: - Persistence

    private struct State: Codable {
        var active: ActiveSession?
        var scheduled: [ScheduledSession]
        var rules: [ScheduleRule]
        var history: [SessionRecord]
        var triggeredOccurrences: [String: Date]
        var lastUsedBlocklistIDs: [UUID]
        // Optional so state saved before the feature still decodes.
        var websiteExceptions: [String]?
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(State.self, from: data)
            active = state.active
            scheduled = state.scheduled
            rules = state.rules
            history = state.history
            triggeredOccurrences = state.triggeredOccurrences
            lastUsedBlocklistIDs = state.lastUsedBlocklistIDs
            websiteExceptions = state.websiteExceptions ?? []
        } catch {
            // The file exists but can't be read: move it aside so the next save
            // can't silently overwrite the whole history with an empty state.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func save() {
        let state = State(active: active, scheduled: scheduled, rules: rules, history: history,
                          triggeredOccurrences: triggeredOccurrences,
                          lastUsedBlocklistIDs: lastUsedBlocklistIDs,
                          websiteExceptions: websiteExceptions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save sessions: \(error)")
        }
    }
}

#if DEBUG
extension SessionStore {
    /// Populates a few months of deterministic sample sessions for UI screenshots.
    func seedDemoData() {
        guard history.isEmpty, rules.isEmpty, scheduled.isEmpty else { return }
        var generator = SeededGenerator(seed: 7)
        let listNames = blocklistStore.blocklists.map(\.name)
        let listIDs = blocklistStore.blocklists.map(\.id)
        lastUsedBlocklistIDs = listIDs

        var seeded: [SessionRecord] = []
        for offset in 1...120 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now)) else { continue }
            guard Double.random(in: 0...1, using: &generator) < 0.7 else { continue }
            let sessionCount = Int.random(in: 1...3, using: &generator)
            for slot in 0..<sessionCount {
                let startHour = [9, 13, 16, 20][min(slot, 3)]
                let start = day.addingTimeInterval(TimeInterval(startHour * 3600 + Int.random(in: 0...45, using: &generator) * 60))
                let plannedMinutes = Int.random(in: 5...22, using: &generator) * 5
                let endedEarly = Double.random(in: 0...1, using: &generator) < 0.15
                let actualMinutes = endedEarly
                    ? max(5, Int(Double(plannedMinutes) * Double.random(in: 0.3...0.8, using: &generator)))
                    : plannedMinutes
                seeded.append(SessionRecord(startedAt: start,
                                            endedAt: start.addingTimeInterval(TimeInterval(actualMinutes * 60)),
                                            plannedMinutes: plannedMinutes,
                                            blocklistNames: listNames,
                                            endedEarly: endedEarly))
            }
        }
        history = seeded

        rules = [
            ScheduleRule(name: "Morning Focus", weekdays: [2, 3, 4, 5, 6],
                         startMinutes: 9 * 60, endMinutes: 11 * 60,
                         blocklistIDs: listIDs, isLocked: false, isEnabled: true),
            ScheduleRule(name: "Wind Down", weekdays: Set(1...7),
                         startMinutes: 21 * 60 + 30, endMinutes: 23 * 60,
                         blocklistIDs: listIDs.isEmpty ? [] : [listIDs[0]],
                         isLocked: true, isEnabled: true),
        ]
        // Mark nearby occurrences as already triggered so seeding never
        // spontaneously starts a session mid-screenshot.
        for rule in rules {
            for offset in -1...1 {
                guard let dayStart = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now)),
                      let occurrence = rule.occurrence(startingOn: calendar.startOfDay(for: dayStart), calendar: calendar) else { continue }
                triggeredOccurrences[occurrenceKey(rule: rule, start: occurrence.start)] = occurrence.end
            }
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) {
            scheduled = [ScheduledSession(startAt: tomorrow.addingTimeInterval(9 * 3600), minutes: 45,
                                          blocklistIDs: listIDs, isLocked: false)]
        }
        save()
    }

    /// Puts the app into a believable mid-session state for UI screenshots.
    /// Builds the session directly instead of going through activate() so the
    /// system notification-permission alert never covers screenshot runs, and
    /// deliberately does NOT save — the demo session must not survive into
    /// normal launches or reach the OS shields.
    func startDemoActiveSession() {
        guard active == nil else { return }
        let lists = blocklistStore.blocklists
        let start = Date.now.addingTimeInterval(-28 * 60)
        active = ActiveSession(id: UUID(), startedAt: start, endsAt: start.addingTimeInterval(75 * 60),
                               blocklistIDs: lists.map(\.id), blocklistNames: lists.map(\.name),
                               isLocked: false, scheduleName: nil)
        now = Date.now
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

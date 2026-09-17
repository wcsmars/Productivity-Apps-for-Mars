import SwiftUI
#if os(iOS) && !targetEnvironment(macCatalyst)
import FamilyControls
#endif

// MARK: - App catalog

/// A commonly blocked app from the built-in catalog.
struct CatalogApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
}

enum AppCatalog {
    static let all: [CatalogApp] = [
        CatalogApp(id: "instagram", name: "Instagram", icon: "camera.fill"),
        CatalogApp(id: "tiktok", name: "TikTok", icon: "music.note"),
        CatalogApp(id: "youtube", name: "YouTube", icon: "play.rectangle.fill"),
        CatalogApp(id: "x", name: "X (Twitter)", icon: "at"),
        CatalogApp(id: "facebook", name: "Facebook", icon: "person.2.fill"),
        CatalogApp(id: "reddit", name: "Reddit", icon: "bubble.left.and.bubble.right.fill"),
        CatalogApp(id: "snapchat", name: "Snapchat", icon: "bolt.fill"),
        CatalogApp(id: "messages", name: "Messages", icon: "message.fill"),
        CatalogApp(id: "whatsapp", name: "WhatsApp", icon: "phone.fill"),
        CatalogApp(id: "discord", name: "Discord", icon: "headphones"),
        CatalogApp(id: "netflix", name: "Netflix", icon: "tv.fill"),
        CatalogApp(id: "twitch", name: "Twitch", icon: "video.fill"),
        CatalogApp(id: "games", name: "Games", icon: "gamecontroller.fill"),
        CatalogApp(id: "news", name: "News", icon: "newspaper.fill"),
        CatalogApp(id: "shopping", name: "Shopping", icon: "cart.fill"),
        CatalogApp(id: "email", name: "Email", icon: "envelope.fill"),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func app(_ id: String) -> CatalogApp? { byID[id] }
}

// MARK: - Keyword catalog

/// Expands distraction keywords ("streaming", "anime", …) into concrete
/// domains so whole categories can be blocked without typing every site.
enum KeywordCatalog {
    static let categories: [String: [String]] = [
        "streaming": ["netflix.com", "hulu.com", "disneyplus.com", "max.com", "primevideo.com",
                      "twitch.tv", "youtube.com", "peacocktv.com", "paramountplus.com", "crunchyroll.com"],
        "anime": ["crunchyroll.com", "funimation.com", "hianime.to", "9animetv.to", "gogoanime.by",
                  "animepahe.ru", "zoro.to", "aniwave.to", "myanimelist.net", "anilist.co"],
        "social": ["facebook.com", "instagram.com", "tiktok.com", "x.com", "twitter.com",
                   "reddit.com", "snapchat.com", "threads.net", "pinterest.com"],
        "video": ["youtube.com", "vimeo.com", "dailymotion.com", "twitch.tv", "tiktok.com"],
        "news": ["cnn.com", "bbc.com", "nytimes.com", "foxnews.com", "reuters.com",
                 "news.google.com", "theguardian.com"],
        "shopping": ["amazon.com", "ebay.com", "aliexpress.com", "temu.com", "shein.com", "etsy.com"],
        "games": ["store.steampowered.com", "epicgames.com", "roblox.com", "miniclip.com",
                  "itch.io", "twitch.tv", "ign.com"],
        "gambling": ["bet365.com", "draftkings.com", "fanduel.com", "pokerstars.com", "stake.com"],
        "sports": ["espn.com", "sports.yahoo.com", "bleacherreport.com", "nba.com", "nfl.com"],
    ]

    /// Suggested chips shown in the editor.
    static var suggestions: [String] { categories.keys.sorted() }

    /// Everything a keyword blocks: its category expansion plus any cataloged
    /// domain that contains the keyword (so "tube" catches youtube.com).
    static func domains(for keyword: String) -> [String] {
        let needle = keyword.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var result = Set(categories[needle] ?? [])
        for domains in categories.values {
            for domain in domains where domain.contains(needle) {
                result.insert(domain)
            }
        }
        return result.sorted()
    }

    static func expand(_ keywords: [String]) -> [String] {
        var all = Set<String>()
        for keyword in keywords {
            all.formUnion(domains(for: keyword))
        }
        return all.sorted()
    }
}

// MARK: - Blocklists

struct Blocklist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var appIDs: [String]
    var websites: [String]
    /// Distraction keywords, auto-expanded to domains via KeywordCatalog.
    var keywords: [String]
    /// Encoded FamilyActivitySelection (stored as Data so Codable/Equatable
    /// synthesis never depends on the FamilyControls types).
    var screenTimeSelectionData: Data?

    init(id: UUID = UUID(), name: String, appIDs: [String] = [], websites: [String] = [],
         keywords: [String] = [], screenTimeSelectionData: Data? = nil) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
        self.websites = websites
        self.keywords = keywords
        self.screenTimeSelectionData = screenTimeSelectionData
    }

    // Custom decoding so blocklists saved before `keywords` existed still load.
    enum CodingKeys: String, CodingKey {
        case id, name, appIDs, websites, keywords, screenTimeSelectionData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appIDs = try container.decode([String].self, forKey: .appIDs)
        websites = try container.decode([String].self, forKey: .websites)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        screenTimeSelectionData = try container.decodeIfPresent(Data.self, forKey: .screenTimeSelectionData)
    }

    /// Every domain this list blocks: typed websites plus keyword expansions.
    var blockedDomains: [String] {
        var all = Set(websites)
        all.formUnion(KeywordCatalog.expand(keywords))
        return all.sorted()
    }

    var apps: [CatalogApp] { appIDs.compactMap(AppCatalog.app) }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// The real device apps/categories/websites chosen via Apple's Screen Time
    /// picker, shielded at the OS level during sessions (needs the Family
    /// Controls entitlement — see ScreenTimeManager). Unavailable on the Mac,
    /// where the raw bytes are simply carried along untouched.
    var screenTimeSelection: FamilyActivitySelection? {
        get {
            screenTimeSelectionData.flatMap {
                try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0)
            }
        }
        set {
            screenTimeSelectionData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var screenTimeItemCount: Int {
        guard let selection = screenTimeSelection else { return 0 }
        return selection.applicationTokens.count + selection.categoryTokens.count
            + selection.webDomainTokens.count
    }
    #else
    var screenTimeItemCount: Int { 0 }
    #endif

    /// Short summary shown on a blocklist card, e.g. "6 apps · 5 websites".
    var itemSummary: String {
        var parts: [String] = []
        if !appIDs.isEmpty { parts.append("\(appIDs.count) app\(appIDs.count == 1 ? "" : "s")") }
        if !websites.isEmpty { parts.append("\(websites.count) website\(websites.count == 1 ? "" : "s")") }
        if !keywords.isEmpty { parts.append("\(keywords.count) keyword\(keywords.count == 1 ? "" : "s")") }
        let deviceItems = screenTimeItemCount
        if deviceItems > 0 { parts.append("\(deviceItems) on device") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

// MARK: - Sessions

/// The focus session currently running.
struct ActiveSession: Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endsAt: Date
    var blocklistIDs: [UUID]
    /// Names snapshotted at start so history stays meaningful if lists are later deleted.
    var blocklistNames: [String]
    var isLocked: Bool
    /// Set when the session was started by a recurring schedule.
    var scheduleName: String?
    /// "Block all websites": the whole web is filtered except
    /// the user's Website Exceptions. Optional so pre-feature saves decode.
    var blocksEverything: Bool?

    var plannedDuration: TimeInterval { endsAt.timeIntervalSince(startedAt) }
    var isBlockingEverything: Bool { blocksEverything ?? false }
}

/// A one-time session queued to start in the future ("Start later").
struct ScheduledSession: Identifiable, Codable, Equatable {
    let id: UUID
    var startAt: Date
    var minutes: Int
    var blocklistIDs: [UUID]
    var isLocked: Bool
    /// Display label (e.g. "Pomodoro 2 of 4"). Optional for pre-feature saves.
    var name: String?
    var blocksEverything: Bool?

    init(id: UUID = UUID(), startAt: Date, minutes: Int, blocklistIDs: [UUID], isLocked: Bool,
         name: String? = nil, blocksEverything: Bool? = nil) {
        self.id = id
        self.startAt = startAt
        self.minutes = minutes
        self.blocklistIDs = blocklistIDs
        self.isLocked = isLocked
        self.name = name
        self.blocksEverything = blocksEverything
    }

    var endAt: Date { startAt.addingTimeInterval(TimeInterval(minutes * 60)) }
    var isBlockingEverything: Bool { blocksEverything ?? false }
}

/// A finished session, kept for history and stats.
struct SessionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var plannedMinutes: Int
    var blocklistNames: [String]
    var scheduleName: String?
    var endedEarly: Bool

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, plannedMinutes: Int,
         blocklistNames: [String], scheduleName: String? = nil, endedEarly: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMinutes = plannedMinutes
        self.blocklistNames = blocklistNames
        self.scheduleName = scheduleName
        self.endedEarly = endedEarly
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var title: String {
        if let scheduleName { return scheduleName }
        return blocklistNames.isEmpty ? "Focus session" : blocklistNames.joined(separator: ", ")
    }
}

// MARK: - Recurring schedules

struct RuleOccurrence: Equatable {
    let start: Date
    let end: Date
}

struct ScheduleRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Calendar weekday numbers (1 = Sunday ... 7 = Saturday).
    var weekdays: Set<Int>
    /// Minutes from midnight.
    var startMinutes: Int
    /// Minutes from midnight; at or before `startMinutes` means the window runs into the next day.
    var endMinutes: Int
    var blocklistIDs: [UUID]
    var isLocked: Bool
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, weekdays: Set<Int>, startMinutes: Int, endMinutes: Int,
         blocklistIDs: [UUID], isLocked: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.blocklistIDs = blocklistIDs
        self.isLocked = isLocked
        self.isEnabled = isEnabled
    }

    var crossesMidnight: Bool { endMinutes <= startMinutes }

    /// The concrete window for the occurrence whose start falls on the given day.
    func occurrence(startingOn dayStart: Date, calendar: Calendar) -> RuleOccurrence? {
        guard let start = calendar.time(atMinutes: startMinutes, on: dayStart) else { return nil }
        let endDayStart: Date? = crossesMidnight
            ? calendar.date(byAdding: .day, value: 1, to: dayStart).map(calendar.startOfDay(for:))
            : dayStart
        guard let endDay = endDayStart,
              let end = calendar.time(atMinutes: endMinutes, on: endDay),
              end > start else { return nil }
        return RuleOccurrence(start: start, end: end)
    }

    /// The occurrence whose window contains `date`, if any. Checks yesterday too so
    /// overnight windows are still honored after midnight.
    func occurrence(containing date: Date, calendar: Calendar) -> RuleOccurrence? {
        let todayStart = calendar.startOfDay(for: date)
        for offset in [0, -1] {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart)
                    .map(calendar.startOfDay(for:)),
                  weekdays.contains(calendar.component(.weekday, from: dayStart)),
                  let occ = occurrence(startingOn: dayStart, calendar: calendar),
                  date >= occ.start, date < occ.end else { continue }
            return occ
        }
        return nil
    }

    /// The first occurrence that is still running or upcoming as of `date`.
    func nextOccurrence(after date: Date, calendar: Calendar) -> RuleOccurrence? {
        guard isEnabled, !weekdays.isEmpty else { return nil }
        let todayStart = calendar.startOfDay(for: date)
        for offset in -1...7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart)
                    .map(calendar.startOfDay(for:)),
                  weekdays.contains(calendar.component(.weekday, from: dayStart)),
                  let occ = occurrence(startingOn: dayStart, calendar: calendar),
                  occ.end > date else { continue }
            return occ
        }
        return nil
    }

    /// Weekday numbers in the locale's display order, e.g. [1,2,...,7] for Sunday-first.
    static func orderedWeekdays(calendar: Calendar) -> [Int] {
        let first = calendar.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    func daysSummary(calendar: Calendar) -> String {
        if weekdays.count == 7 { return "Every day" }
        let symbols = calendar.shortWeekdaySymbols
        return Self.orderedWeekdays(calendar: calendar)
            .filter(weekdays.contains)
            .map { symbols[$0 - 1] }
            .joined(separator: " ")
    }

    func timeSummary(calendar: Calendar) -> String {
        let text = "\(Format.minutesOfDay(startMinutes, calendar: calendar)) – \(Format.minutesOfDay(endMinutes, calendar: calendar))"
        return crossesMidnight ? "\(text) (+1 day)" : text
    }
}

/// The soonest queued or recurring session, shown as "Up next" on the Focus tab.
struct UpcomingSession: Equatable {
    var title: String
    var start: Date
    var end: Date
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    /// "47:12" under an hour, "1:23:45" above it.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Renders minutes-from-midnight as a localized clock time, e.g. "9:00 AM".
    static func minutesOfDay(_ minutes: Int, calendar: Calendar = .current) -> String {
        let dayStart = calendar.startOfDay(for: .now)
        let date = calendar.time(atMinutes: minutes, on: dayStart) ?? dayStart
        return date.formatted(date: .omitted, time: .shortened)
    }
}

extension Calendar {
    /// The wall-clock time `minutes` after midnight on the given day. Uses
    /// component matching, not elapsed-time arithmetic, so 9:00 stays 9:00
    /// even on days that gain or lose an hour to DST.
    func time(atMinutes minutes: Int, on dayStart: Date) -> Date? {
        date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: dayStart)
    }

    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

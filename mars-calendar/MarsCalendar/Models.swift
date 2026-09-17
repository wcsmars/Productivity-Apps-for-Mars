import SwiftUI

// MARK: - Calendar sources

/// An event calendar or reminder list, mapped from EventKit (or built-in in demo mode).
struct CalendarSource: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
    let allowsModifications: Bool
}

/// A calendar account source (iCloud, Google/CalDAV, Exchange, local) that new
/// calendars can be created in.
struct AccountSource: Identifiable, Equatable {
    let id: String
    let title: String
    /// Human kind, e.g. "iCloud", "CalDAV", "Exchange", "On my iPhone".
    let kind: String
}

/// A named group of visible calendars/lists — Fantastical-style Calendar Sets.
struct CalendarSet: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// IDs of the calendars AND task lists this set shows.
    var visibleIDs: Set<String>

    init(id: UUID = UUID(), name: String, visibleIDs: Set<String>) {
        self.id = id
        self.name = name
        self.visibleIDs = visibleIDs
    }
}

/// One day's forecast for the list headers (SF Symbol + temperatures in °C or °F
/// per locale, already formatted by the service).
struct DayWeather: Equatable {
    let symbol: String
    let high: Int
    let low: Int
}

// MARK: - Items

/// An event participant, read from the invitation (EventKit exposes these read-only).
struct Attendee: Equatable {
    enum Status: Equatable {
        case accepted, declined, tentative, pending, unknown

        var label: String {
            switch self {
            case .accepted: "Accepted"
            case .declined: "Declined"
            case .tentative: "Maybe"
            case .pending: "Invited"
            case .unknown: "—"
            }
        }
    }

    let name: String
    let status: Status
    let isOrganizer: Bool
}

/// One occurrence of a calendar event. `id` is occurrence-unique so recurring
/// events can repeat in lists; `eventID` is the underlying EventKit identifier.
struct EventItem: Identifiable, Equatable {
    let id: String
    let eventID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var location: String?
    var notes: String?
    var hasRecurrence: Bool
    /// Human summary like "Repeats every week", nil when not recurring.
    var recurrenceText: String?
    /// Minutes before start of the first alarm, if one is set.
    var alertMinutesBefore: Int?
    /// Invitees, read-only from the invitation.
    var attendees: [Attendee] = []
    /// The event's URL field (often a conference link).
    var url: URL?
    /// The event's time zone identifier when it differs from the device's.
    var timeZoneID: String?
}

/// A reminder shown as a task. Priority is app-level: 0 none, 1 (!) low,
/// 2 (!!) medium, 3 (!!!) high.
struct TaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var due: Date?
    var hasDueTime: Bool
    var isCompleted: Bool
    var priority: Int
    var listID: String
    var notes: String?
    var hasRecurrence: Bool

    var priorityMarks: String { String(repeating: "!", count: min(priority, 3)) }
}

// MARK: - Drafts (parser output / quick add)

struct RecurrenceDraft: Equatable {
    enum Frequency: Equatable { case daily, weekly, monthly, yearly }
    var frequency: Frequency
    var interval: Int = 1
    /// Weekday numbers (1 = Sunday ... 7 = Saturday) for weekly rules like "every Mon and Wed".
    var weekdays: [Int]?
    var endDate: Date?
    /// Human summary for the preview card, e.g. "Every 2 weeks".
    var text: String
}

/// What the quick-add parser understood. Views resolve nil fields against
/// the store's defaults when saving.
struct ItemDraft: Equatable {
    enum Kind: Equatable { case event, task }

    var kind: Kind = .event
    var title: String = ""
    /// Resolved start instant. nil means no date/time was recognized.
    var start: Date?
    /// Explicit end from range syntax ("3-4pm"); wins over duration.
    var end: Date?
    /// From "for 45 minutes"; nil means use the default event duration.
    var durationMinutes: Int?
    var isAllDay: Bool = false
    /// Distinguishes an explicit all-day instruction from a date without a time.
    var hasExplicitAllDay: Bool = false
    /// Last day of a multi-day all-day span ("from June 5 to June 12").
    var endDay: Date?
    /// True when a clock time was recognized (false = date only).
    var hasTime: Bool = false
    /// True when the day came from an explicit date token ("tomorrow", "Oct 14",
    /// "Friday") rather than being defaulted from a bare time — quick-add uses
    /// this to let the selected calendar day win over the default.
    var hasExplicitDate: Bool = false
    var location: String?
    /// Notes carried from a saved template.
    var notes: String?
    /// Calendar resolved from a "/work" hint.
    var calendarID: String?
    var alertMinutesBefore: Int?
    var recurrence: RecurrenceDraft?
    /// Tasks: 0 none, 1-3 from trailing !/!!/!!!.
    var priority: Int = 0
    /// Invalid typed values must be corrected before the draft can be saved.
    var validationErrors: [String] = []
}

// MARK: - Formatting

enum Format {
    /// "1h 30m", "1h", or "45m" from seconds.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Short clock time, e.g. "1:30 PM".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "1:00 – 2:30 PM" style range.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// Day-list header, e.g. "Tuesday, July 22".
    static func dayHeader(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// Compact date for rows and chips, e.g. "Jul 22".
    static func shortDate(_ day: Date) -> String {
        day.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Relative label for a day ("Today", "Tomorrow", "Yesterday") or nil.
    static func relativeDay(_ day: Date, calendar: Calendar = .current) -> String? {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return nil
    }
}

// MARK: - Calendar helpers

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    /// A time on a given day built with component matching so it survives DST days.
    func time(atMinutes minutes: Int, on day: Date) -> Date? {
        date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: startOfDay(for: day))
    }
}

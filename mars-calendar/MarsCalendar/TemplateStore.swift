import SwiftUI

/// A reusable event blueprint ("Workout", "1:1 with Sam", ...) that quick-add
/// can apply: everything but the date is remembered.
struct EventTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var title: String
    /// nil means use the store's default event duration (or all-day).
    var durationMinutes: Int?
    var isAllDay: Bool
    var calendarID: String?
    var location: String?
    var alertMinutesBefore: Int?
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        title: String,
        durationMinutes: Int? = nil,
        isAllDay: Bool = false,
        calendarID: String? = nil,
        location: String? = nil,
        alertMinutesBefore: Int? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.durationMinutes = durationMinutes
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.location = location
        self.alertMinutesBefore = alertMinutesBefore
        self.notes = notes
    }

    /// Retains saved fields while allowing dates, times, and other instructions
    /// appended after the literal title to override the template defaults.
    func draft(from input: String, reference: Date = .now, calendar: Calendar = .current,
               calendars: [CalendarSource] = [], defaultTime: Date) -> ItemDraft {
        var draft = QuickParse.parse(input, reference: reference, calendar: calendar,
                                     calendars: calendars, literalPrefix: title)
        draft.durationMinutes = draft.durationMinutes ?? durationMinutes
        draft.calendarID = draft.calendarID ?? calendarID
        draft.location = draft.location ?? location
        draft.alertMinutesBefore = draft.alertMinutesBefore ?? alertMinutesBefore
        draft.notes = notes
        if !draft.hasTime && !draft.hasExplicitAllDay {
            draft.isAllDay = isAllDay
            if !isAllDay {
                let day = draft.start ?? reference
                let time = calendar.dateComponents([.hour, .minute], from: defaultTime)
                draft.start = calendar.date(bySettingHour: time.hour ?? 9,
                                            minute: time.minute ?? 0, second: 0, of: day) ?? day
                draft.hasTime = true
            }
        }
        return draft
    }
}

/// Event templates persisted as JSON in UserDefaults ("eventTemplates").
@MainActor
final class TemplateStore: ObservableObject {
    @Published private(set) var templates: [EventTemplate]

    private static let defaultsKey = "eventTemplates"
    private let defaults = UserDefaults.standard

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([EventTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = []
        }
    }

    func add(_ template: EventTemplate) {
        templates.append(template)
        persist()
    }

    func delete(_ template: EventTemplate) {
        templates.removeAll { $0.id == template.id }
        persist()
    }

    /// Captures an existing event's reusable fields as a named template.
    static func template(named name: String, from event: EventItem) -> EventTemplate {
        EventTemplate(
            name: name,
            title: event.title,
            durationMinutes: event.isAllDay
                ? nil
                : max(Int(event.end.timeIntervalSince(event.start) / 60), 0),
            isAllDay: event.isAllDay,
            calendarID: event.calendarID,
            location: event.location,
            alertMinutesBefore: event.alertMinutesBefore,
            notes: event.notes
        )
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

import Foundation

/// Compiles the app's real parser and models; no copied parser or test stubs.
@main
struct QuickParseTests {
    @MainActor static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 10))!
        var checks = 0
        var failures: [String] = []

        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }
        func parse(_ text: String, at date: Date? = nil) -> ItemDraft {
            QuickParse.parse(text, reference: date ?? reference, calendar: calendar)
        }
        func parts(_ date: Date?) -> DateComponents {
            date.map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) } ?? DateComponents()
        }

        let meeting = parse("Meeting Friday 3-4pm")
        expect(meeting.validationErrors.isEmpty && meeting.title == "Meeting", "ordinary title and valid range")
        expect(parts(meeting.start).day == 24 && parts(meeting.start).hour == 15 && parts(meeting.end).hour == 16, "weekday and inherited meridiem")
        let dentist = parse("Dentist Oct 14 9am for 45 minutes alert 30 minutes")
        expect(dentist.validationErrors.isEmpty && parts(dentist.start).month == 10 && parts(dentist.start).day == 14, "month-name date")
        expect(dentist.durationMinutes == 45 && dentist.alertMinutesBefore == 30, "duration and alert")
        let repeatDraft = parse("Standup every weekday at 9:30am until Aug 1")
        expect(repeatDraft.validationErrors.isEmpty && repeatDraft.recurrence?.weekdays == [2, 3, 4, 5, 6], "weekday recurrence")
        expect(parts(repeatDraft.recurrence?.endDate).month == 8 && parts(repeatDraft.recurrence?.endDate).day == 2, "inclusive recurrence end")
        let vacation = parse("Vacation from June 5 to June 12")
        expect(vacation.validationErrors.isEmpty && vacation.isAllDay && parts(vacation.start).day == 5 && parts(vacation.endDay).day == 12, "all-day span")
        let task = parse("todo Pay rent on the 1st every month !!")
        expect(task.validationErrors.isEmpty && task.kind == .task && task.priority == 2 && parts(task.start).day == 1 && task.recurrence?.frequency == .monthly, "monthly reminder")
        expect(parse("Dinner at 8").start.map { parts($0).hour == 20 } == true, "next upcoming bare hour")
        let overnight = parse("Shift tomorrow 23:00-01:30")
        expect(overnight.validationErrors.isEmpty && parts(overnight.end).day == 24 && parts(overnight.end).hour == 1, "overnight 24-hour range")
        expect(parse("Run for 1h30m").durationMinutes == 90, "compact duration")
        expect(parse("Run for 1.5 hours and 15 minutes").durationMinutes == 105, "decimal and mixed duration")
        expect(parts(parse("Meeting in 2 weeks").start).day == 5, "relative weeks")
        expect(parse("Meeting alert 2 hours").alertMinutesBefore == 120, "hour alert")
        let quoted = parse("Discuss \"tomorrow at 99:99\" tomorrow 1pm at Cafe Rio")
        expect(quoted.validationErrors.isEmpty && quoted.title == "Discuss tomorrow at 99:99" && quoted.location == "Cafe Rio", "quoted text remains literal")

        let huge = String(repeating: "9", count: 400)
        let invalidInputs = [
            "Run for \(huge) hours", "Run for 9223372036854775807 minutes",
            "Run for 153722867280912931 hours", "Run for 525601 minutes", "Run for 0 minutes", "Run for 0h",
            "Meeting alert \(Int.max) hours", "Meeting alert \(huge) minutes", "Meeting alarm 525601 minutes",
            "Meeting in \(Int.max) weeks", "Meeting in \(huge) days", "Meeting in 36501 days",
            "Meeting every \(Int.max) years", "Meeting every \(huge) days", "Meeting every 0 days", "Meeting every 1000 weeks",
            "Meeting February 30", "Meeting February 29 2025", "Meeting June 99", "Meeting 2/30/2026", "Meeting 13/1/2026",
            "Meeting January 1 0000", "Meeting 1/1/0000", "Meeting on the 99th", "Meeting at 99:99", "Meeting 13pm", "Meeting 0am",
            "Meeting 11:75am-1pm", "Meeting 09:30-27:00", "Meeting from June 5 to June 99"
        ]
        for text in invalidInputs {
            let draft = parse(text)
            expect(!draft.validationErrors.isEmpty, "reject invalid input: \(text.prefix(75))")
        }
        expect(parse("Run for 525600 minutes").durationMinutes == 525600, "duration upper bound")
        expect(parse("Meeting alert 0 minutes").alertMinutesBefore == 0, "zero-minute alert remains valid")
        expect(parse("Meeting every 999 days").recurrence?.interval == 999, "recurrence upper bound")
        let leap = parse("Meeting February 29")
        expect(leap.validationErrors.isEmpty && parts(leap.start).year == 2028 && parts(leap.start).day == 29, "next leap day")
        let february = calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 10))!
        let month31 = parse("Pay on the 31st", at: february)
        expect(month31.validationErrors.isEmpty && parts(month31.start).month == 3 && parts(month31.start).day == 31, "skip month without requested day")
        let lastDay = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31, hour: 10))!
        expect(!parse("Meeting tomorrow 1pm", at: lastDay).validationErrors.isEmpty, "date boundary fails safely")

        // Exercise captured event fields through the same template-to-draft
        // path as Quick Add, including a title that looks like parser syntax.
        let literalTitle = "todo Friday at 99:99 \"Review\" !!! 🗓️"
        let original = EventItem(id: "event", eventID: "event", title: literalTitle,
                                 start: reference, end: reference.addingTimeInterval(45 * 60),
                                 isAllDay: false, calendarID: "work", location: "Friday Cafe",
                                 notes: "Bring the report.\nDiscuss next steps.", hasRecurrence: false,
                                 alertMinutesBefore: 10)
        let template = TemplateStore.template(named: "Review", from: original)
        let defaultTime = calendar.date(bySettingHour: 9, minute: 15, second: 0, of: reference)!
        func apply(_ template: EventTemplate, suffix: String = "") -> ItemDraft {
            template.draft(from: template.title + suffix, reference: reference,
                           calendar: calendar, defaultTime: defaultTime)
        }
        let restored = apply(template)
        expect(restored.title == literalTitle && restored.kind == .event && restored.validationErrors.isEmpty,
               "template title, quotes, emoji, and parser-like words stay literal")
        expect(restored.hasTime && !restored.isAllDay && restored.durationMinutes == 45
               && parts(restored.start).hour == 9 && parts(restored.start).minute == 15,
               "timed template keeps its mode and duration using the chosen time")
        expect(restored.notes == original.notes && restored.location == original.location
               && restored.calendarID == "work" && restored.alertMinutesBefore == 10,
               "template carries notes, literal location, calendar, and alert into the draft")
        let tomorrow = apply(template, suffix: " tomorrow")
        expect(tomorrow.hasTime && !tomorrow.isAllDay && parts(tomorrow.start).day == 23,
               "appending only a date preserves a timed template")
        let amended = apply(template, suffix: " tomorrow 3-4pm at New Office alert 30 minutes")
        expect(amended.title == literalTitle && parts(amended.start).day == 23
               && parts(amended.start).hour == 15 && parts(amended.end).hour == 16
               && amended.location == "New Office" && amended.alertMinutesBefore == 30,
               "appended scheduling instructions override template defaults without parsing its title")
        expect(apply(template, suffix: " tomorrow all-day").isAllDay,
               "explicit all-day instruction overrides a timed template")
        let span = apply(template, suffix: " from June 5 to June 12")
        expect(span.isAllDay && parts(span.endDay).day == 12, "explicit all-day span overrides template time")
        var allDayTemplate = template
        allDayTemplate.isAllDay = true
        allDayTemplate.durationMinutes = nil
        expect(apply(allDayTemplate).isAllDay && !apply(allDayTemplate).hasTime,
               "all-day template remains all-day")
        expect(apply(allDayTemplate, suffix: " tomorrow 2pm").hasTime,
               "explicit time can override an all-day template")
        let renamed = template.draft(from: "New title tomorrow 2pm", reference: reference,
                                     calendar: calendar, defaultTime: defaultTime)
        expect(renamed.title == "New title" && renamed.hasTime && renamed.notes == original.notes,
               "edited template title uses normal input parsing while retaining saved fields")

        if failures.isEmpty {
            print("Passed \(checks) parser and template regression checks.")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            fatalError("\(failures.count) of \(checks) parser checks failed")
        }
    }
}

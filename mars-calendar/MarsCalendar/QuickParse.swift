import Foundation

/// Fantastical-style natural-language parser for the quick-add field.
///
/// Strategy: run ordered regex passes over a working copy of the input,
/// blanking each recognized token with spaces (so offsets stay stable).
/// Dates are extracted BEFORE times so a date's day number can never be
/// mistaken for the start of a time range ("June 5 until 7pm"). Quoted
/// spans are replaced by positional sentinels and restored at the end.
/// Whatever survives, minus dangling connector words, becomes the title.
enum QuickParse {
    // Keep parsed values within practical calendar ranges before arithmetic or
    // conversion to EventKit's integer and date representations.
    private static let maximumMinutes = 365 * 24 * 60
    private static let maximumRelativeDays = 100 * 365

    static func parse(
        _ input: String,
        reference: Date = .now,
        calendar: Calendar = .current,
        calendars: [CalendarSource] = [],
        literalPrefix: String? = nil
    ) -> ItemDraft {
        var draft = ItemDraft()
        let working = NSMutableString(string: input)

        // 1. Quoted spans are kept literal (and in place) in the title: each is
        //    swapped for a run of a per-quote sentinel character so later passes
        //    can't touch it, then restored positionally at the end.
        var quoted: [String] = []
        // A saved template title is data, including words such as "Friday" or
        // "todo". Protect its unchanged prefix while parsing appended input.
        if let literalPrefix, !literalPrefix.isEmpty, input.hasPrefix(literalPrefix) {
            let length = (literalPrefix as NSString).length
            working.replaceCharacters(in: NSRange(location: 0, length: length),
                                      with: String(repeating: "\u{E000}", count: length))
            quoted.append(literalPrefix)
        }
        while let range = firstRange("\"([^\"]*)\"", in: working), quoted.count < 0xFF {
            let content = (working.substring(with: range) as NSString)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let sentinel = String(repeating: String(UnicodeScalar(0xE000 + quoted.count)!), count: range.length)
            working.replaceCharacters(in: range, with: sentinel)
            quoted.append(content)
        }

        // 2. Leading todo/task/reminder marker flips to a task.
        if consume("^\\s*(?:todo|task|reminder)\\b:?", in: working) != nil {
            draft.kind = .task
        }

        // 3. Trailing !/!!/!!! priority (tasks).
        if let captures = consume("(!{1,3})\\s*$", in: working) {
            draft.priority = captures[1]?.count ?? 0
            if draft.priority > 0 && draft.kind == .event { draft.kind = .task }
        }

        // 4. /calendar hint, prefix-matched against calendar titles.
        if let captures = consume("(?<=\\s|^)/([\\p{L}\\p{N}]+)", in: working),
           let hint = captures[1]?.lowercased() {
            draft.calendarID = calendars.first { $0.title.lowercased().hasPrefix(hint) }?.id
        }

        // 5. Alerts.
        if let captures = consume("\\bremind me\\s+(\\d+)\\s*(minutes?|mins?|m|hours?|hrs?|h)\\s+before\\b", in: working)
            ?? consume("\\b(?:alert|alarm)\\s+(\\d+)\\s*(minutes?|mins?|m|hours?|hrs?|h)?\\b", in: working) {
            let isHours = captures[2]?.lowercased().hasPrefix("h") ?? false
            if let amount = Int(captures[1] ?? ""),
               (0...(maximumMinutes / (isHours ? 60 : 1))).contains(amount) {
                draft.alertMinutesBefore = amount * (isHours ? 60 : 1)
            } else {
                draft.validationErrors.append("Use an alert between 0 minutes and 365 days before the event.")
            }
        }

        // 6. Recurrence (before dates, so "every Monday" isn't read as a date).
        var recurrence = parseRecurrence(in: working, errors: &draft.validationErrors)

        // 7. Dates — BEFORE any time pass, so day numbers stay dates.
        let dates = parseDates(in: working, reference: reference, calendar: calendar, errors: &draft.validationErrors)

        // 8. Time range, e.g. "3-4pm", "3pm to 4pm", "7:45am-10:12am", "15:00-16:30".
        var startTime: (hour: Int, minute: Int)?
        var endTime: (hour: Int, minute: Int)?
        var invalidTime = false
        if let captures = consume("\\b(?:at\\s+)?(\\d{1,2})(?:[:.](\\d{2}))?\\s*(am|pm)?\\s*(?:-|–|—|to|until)\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*(am|pm)\\b", in: working) {
            let rawStart = (h: Int(captures[1] ?? "") ?? 0, m: Int(captures[2] ?? "0") ?? 0)
            let rawEnd = (h: Int(captures[4] ?? "") ?? 0, m: Int(captures[5] ?? "0") ?? 0)
            let endMeridiem = captures[6]?.lowercased()
            invalidTime = !validClock(rawStart, meridiem: captures[3] ?? endMeridiem)
                || !validClock(rawEnd, meridiem: endMeridiem)
            var end = apply(meridiem: endMeridiem, to: rawEnd)
            var start: (hour: Int, minute: Int)
            if let startMeridiem = captures[3]?.lowercased() {
                start = apply(meridiem: startMeridiem, to: rawStart)
            } else {
                // Inherit the end meridiem; "9-5pm" then flips 21:00 back to 9:00.
                start = apply(meridiem: endMeridiem, to: rawStart)
                if minutes(start) >= minutes(end), start.hour >= 12 {
                    start.hour -= 12
                }
            }
            if minutes(end) <= minutes(start) { end.hour += 24 } // crosses midnight
            startTime = start
            endTime = end
        } else if let captures = consume("\\b(?:at\\s+)?(\\d{1,2})[:.](\\d{2})\\s*(?:-|–|to)\\s*(\\d{1,2})[:.](\\d{2})\\b", in: working) {
            startTime = (Int(captures[1] ?? "") ?? 0, Int(captures[2] ?? "0") ?? 0)
            endTime = (Int(captures[3] ?? "") ?? 0, Int(captures[4] ?? "0") ?? 0)
            if let s = startTime, var e = endTime {
                invalidTime = !validClock((s.hour, s.minute)) || !validClock((e.hour, e.minute))
                if minutes(e) <= minutes(s) { e.hour += 24 }
                endTime = e
            }
        }

        // 9. Single time. Each form swallows a leading "at" so no dangling
        //    connector is left for the location pass to latch onto.
        var impliedEveningIfBare = false
        var bareHourAmbiguous = false
        if startTime == nil {
            if let captures = consume("\\b(?:at\\s+)?(\\d{1,2})[:.](\\d{2})\\s*(am|pm)?\\b", in: working) {
                let raw = (h: Int(captures[1] ?? "") ?? 0, m: Int(captures[2] ?? "0") ?? 0)
                invalidTime = !validClock(raw, meridiem: captures[3])
                startTime = captures[3] != nil
                    ? apply(meridiem: captures[3]?.lowercased(), to: raw)
                    : (raw.h, raw.m)
            } else if let captures = consume("\\b(?:at\\s+)?(\\d{1,2})\\s*(am|pm)\\b", in: working) {
                let raw = (h: Int(captures[1] ?? "") ?? 0, m: 0)
                invalidTime = !validClock(raw, meridiem: captures[2])
                startTime = apply(meridiem: captures[2]?.lowercased(), to: raw)
            } else if let captures = consume("\\bat\\s+(\\d{1,2})\\b(?![:./\\d])", in: working) {
                let hour = Int(captures[1] ?? "") ?? 0
                startTime = daytimeGuess(hour: hour)
                bareHourAmbiguous = (7...11).contains(hour)
            } else if consume("\\b(?:at\\s+)?noon\\b", in: working) != nil {
                startTime = (12, 0)
            } else if consume("\\b(?:at\\s+)?midnight\\b", in: working) != nil {
                startTime = (0, 0)
            } else {
                impliedEveningIfBare = true
            }
        }

        if let start = startTime,
           invalidTime || !(0...23).contains(start.hour) || !(0...59).contains(start.minute) {
            draft.validationErrors.append("Use a valid clock time (00:00–23:59 or 1–12 am/pm).")
            startTime = nil
            endTime = nil
        }

        // 10. All-day flag.
        if consume("\\ball[- ]day\\b", in: working) != nil {
            draft.isAllDay = true
            draft.hasExplicitAllDay = true
            startTime = nil
            endTime = nil
        }

        // 11. Duration.
        if let captures = consume("\\bfor\\s+(\\d{1,2})h(?:(\\d{1,2})m?)?\\b", in: working) {
            draft.durationMinutes = (Int(captures[1] ?? "") ?? 0) * 60 + (Int(captures[2] ?? "0") ?? 0)
        } else if let captures = consume("\\bfor\\s+(\\d+(?:\\.\\d+)?)\\s*(minutes?|mins?|m|hours?|hrs?|h)\\b(?:\\s*(?:and\\s+)?(\\d{1,2})\\s*(?:minutes?|mins?|m)\\b)?", in: working) {
            let isHours = captures[2]?.lowercased().hasPrefix("h") ?? false
            let extra = Double(captures[3] ?? "0") ?? 0
            let total = ((Double(captures[1] ?? "") ?? .infinity) * (isHours ? 60 : 1)).rounded() + extra
            if total.isFinite, (1...Double(maximumMinutes)).contains(total) {
                draft.durationMinutes = Int(total)
            } else {
                draft.validationErrors.append("Use a duration between 1 minute and 365 days.")
            }
        }
        if draft.durationMinutes == 0 {
            draft.durationMinutes = nil
            draft.validationErrors.append("Use a duration of at least 1 minute.")
        }

        // 12. "tonight" with no explicit time implies the evening.
        if dates.impliedTonight && startTime == nil && impliedEveningIfBare && !draft.isAllDay {
            startTime = (19, 0)
        }

        // A bare ambiguous hour with no explicit date reads as the next upcoming
        // occurrence: "Dinner at 8" typed at 10 AM means 8 PM today, not 8 AM tomorrow.
        if bareHourAmbiguous, dates.first == nil, var time = startTime {
            let today = calendar.startOfDay(for: reference)
            let morning = dateBySetting(time: time, on: today, calendar: calendar)
            if morning <= reference {
                let evening = dateBySetting(time: (time.hour + 12, time.minute), on: today, calendar: calendar)
                if evening > reference { time.hour += 12 }
                startTime = time
            }
        }

        // Resolve day + time into concrete dates.
        resolve(
            into: &draft,
            dates: dates,
            startTime: startTime,
            endTime: endTime,
            recurrence: &recurrence,
            reference: reference,
            calendar: calendar
        )
        draft.recurrence = recurrence
        for date in [draft.start, draft.end, draft.endDay, recurrence?.endDate].compactMap({ $0 }) {
            if !(1...9999).contains(calendar.component(.year, from: date)) {
                draft.validationErrors.append("Use a date between years 1 and 9999.")
                break
            }
        }

        // 13. Location: a surviving "at <phrase>". Exactly one space after "at"
        //     so the match can never cross a blanked seam ("Lunch at [12pm] with
        //     Sam" must not become location "with Sam"); phrases end at a blanked
        //     gap (2+ spaces) or the end of the string.
        if let captures = consume("\\bat\\s(\\S.*?)(?=\\s{2,}|\\s*$)", in: working),
           let raw = captures[1] {
            let place = restoreQuotes(raw, quoted: quoted).trimmingCharacters(in: .whitespaces)
            if !place.isEmpty { draft.location = place }
        }

        // 14. Title = leftovers, segment by segment, with dangling connectors
        //     dropped and quoted spans restored in place.
        draft.title = buildTitle(from: working as String, quoted: quoted)
        return draft
    }

    // MARK: - Recurrence

    private static let weekdayPattern = "(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?"

    private static func parseRecurrence(in working: NSMutableString, errors: inout [String]) -> RecurrenceDraft? {
        if let captures = consume(":(daily|weekly|monthly|yearly)\\b", in: working) {
            switch captures[1]?.lowercased() {
            case "daily": return RecurrenceDraft(frequency: .daily, text: "Every day")
            case "weekly": return RecurrenceDraft(frequency: .weekly, text: "Every week")
            case "monthly": return RecurrenceDraft(frequency: .monthly, text: "Every month")
            default: return RecurrenceDraft(frequency: .yearly, text: "Every year")
            }
        }
        if consume("\\bevery\\s+weekday\\b", in: working) != nil {
            return RecurrenceDraft(frequency: .weekly, weekdays: [2, 3, 4, 5, 6], text: "Every weekday")
        }
        if let captures = consume("\\bevery\\s+(\\d+)\\s+(day|week|month|year)s?\\b", in: working) {
            guard let interval = Int(captures[1] ?? ""), (1...999).contains(interval) else {
                errors.append("Use a repeat interval between 1 and 999.")
                return nil
            }
            let unit = captures[2]?.lowercased() ?? "week"
            let frequency: RecurrenceDraft.Frequency = ["day": .daily, "week": .weekly, "month": .monthly, "year": .yearly][unit] ?? .weekly
            return RecurrenceDraft(frequency: frequency, interval: interval, text: "Every \(interval) \(unit)s")
        }
        if let captures = consume("\\bevery\\s+(day|week|month|year)\\b", in: working) {
            let unit = captures[1]?.lowercased() ?? "week"
            let frequency: RecurrenceDraft.Frequency = ["day": .daily, "week": .weekly, "month": .monthly, "year": .yearly][unit] ?? .weekly
            return RecurrenceDraft(frequency: frequency, text: "Every \(unit)")
        }
        let listPattern = "\\bevery\\s+(\(weekdayPattern)s?(?:(?:\\s*,\\s*|\\s+and\\s+)\(weekdayPattern)s?)*)\\b"
        if let captures = consume(listPattern, in: working), let list = captures[1] {
            let days = weekdayNumbers(in: list)
            if !days.isEmpty {
                return RecurrenceDraft(frequency: .weekly, weekdays: days, text: recurrenceText(forWeekdays: days))
            }
        }
        // Plural weekdays act like "every": "Tuesdays and Thursdays at 5pm".
        let pluralPattern = "\\b(\(weekdayPattern)s(?:(?:\\s*,\\s*|\\s+and\\s+)\(weekdayPattern)s)*)\\b"
        if let captures = consume(pluralPattern, in: working), let list = captures[1] {
            let days = weekdayNumbers(in: list)
            if !days.isEmpty {
                return RecurrenceDraft(frequency: .weekly, weekdays: days, text: recurrenceText(forWeekdays: days))
            }
        }
        return nil
    }

    private static func weekdayNumbers(in text: String) -> [Int] {
        let prefixes: [(String, Int)] = [
            ("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7),
        ]
        var result: [Int] = []
        for word in text.lowercased().components(separatedBy: CharacterSet(charactersIn: ", ")) where !word.isEmpty {
            let clean = word == "and" ? "" : word
            for (prefix, number) in prefixes where clean.hasPrefix(prefix) && !result.contains(number) {
                result.append(number)
            }
        }
        return result
    }

    private static func recurrenceText(forWeekdays days: [Int]) -> String {
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return "Every " + days.compactMap { names[$0] }.joined(separator: ", ")
    }

    // MARK: - Dates

    private struct ParsedDates {
        var first: Date?
        var second: Date?
        var isSpan = false          // two dates joined by from/to
        /// A single date that was introduced by "until"/"to"/"through" — an end
        /// bound ("Standup every weekday until Aug 1"), not a start.
        var firstIsEndBound = false
        var impliedTonight = false
        var dayOfMonth: Int?        // "on the 15th"
        var weekdays: [Int] = []    // bare weekday mentions, in order
    }

    private static let monthPattern = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

    private static func parseDates(in working: NSMutableString, reference: Date, calendar: Calendar, errors: inout [String]) -> ParsedDates {
        var result = ParsedDates()
        let today = calendar.startOfDay(for: reference)

        func record(_ day: Date, precededByFrom: Bool, precededByTo: Bool) {
            if result.first == nil {
                result.first = day
                result.firstIsEndBound = precededByTo
            } else if result.second == nil {
                result.second = day
                if precededByTo { result.isSpan = true }
            }
        }

        // Helper that also consumes an immediately preceding from/to/until/through.
        func consumeDate(_ pattern: String, _ build: ([String?]) -> Date?) -> Bool {
            let full = "\\b(from\\s+|to\\s+|until\\s+|through\\s+)?" + pattern
            guard let captures = consume(full, in: working) else { return false }
            let connector = captures[1]?.trimmingCharacters(in: .whitespaces).lowercased()
            guard let day = build(Array(captures.dropFirst())) else {
                errors.append("Check the date: \(captures[0] ?? "").")
                return true
            }
            record(
                day,
                precededByFrom: connector == "from",
                precededByTo: connector == "to" || connector == "until" || connector == "through"
            )
            return true
        }

        // Relative days.
        if consume("\\bday after tomorrow\\b", in: working) != nil,
           let day = calendar.date(byAdding: .day, value: 2, to: today) {
            record(day, precededByFrom: false, precededByTo: false)
        }
        if consume("\\btomorrow\\b", in: working) != nil,
           let day = calendar.date(byAdding: .day, value: 1, to: today) {
            record(day, precededByFrom: false, precededByTo: false)
        }
        if consume("\\btonight\\b", in: working) != nil {
            result.impliedTonight = true
            record(today, precededByFrom: false, precededByTo: false)
        }
        if consume("\\btoday\\b", in: working) != nil {
            record(today, precededByFrom: false, precededByTo: false)
        }

        // "in 3 days" / "in 2 weeks".
        if let captures = consume("\\bin\\s+(\\d+)\\s+(days?|weeks?)\\b", in: working) {
            let unit = (captures[2]?.lowercased().hasPrefix("week") ?? false) ? 7 : 1
            if let amount = Int(captures[1] ?? ""), (0...(maximumRelativeDays / unit)).contains(amount),
               let day = calendar.date(byAdding: .day, value: amount * unit, to: today) {
                record(day, precededByFrom: false, precededByTo: false)
            } else {
                errors.append("Use a relative date within the next 100 years.")
            }
        }

        // Month-name dates, both orders — loop so spans like "June 5 to June 12" collect both.
        while consumeDate("(\(monthPattern))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s*(\\d{4}))?\\b", { captures in
            monthNameDate(month: captures[1], day: captures[2], year: captures[3], reference: reference, calendar: calendar)
        }) {}
        while consumeDate("(\\d{1,2})(?:st|nd|rd|th)?\\s+(\(monthPattern))\\b(?:,?\\s*(\\d{4}))?", { captures in
            monthNameDate(month: captures[2], day: captures[1], year: captures[3], reference: reference, calendar: calendar)
        }) {}

        // Numeric M/D or M/D/Y.
        while consumeDate("(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b", { captures in
            numericDate(month: captures[1], day: captures[2], year: captures[3], reference: reference, calendar: calendar)
        }) {}

        // "on the 15th" — day of the current (or next) month.
        if let captures = consume("\\b(?:on\\s+)?the\\s+(\\d{1,2})(?:st|nd|rd|th)\\b", in: working) {
            if let day = Int(captures[1] ?? ""), (1...31).contains(day) {
                result.dayOfMonth = day
            } else {
                errors.append("Use a day of the month between 1 and 31.")
            }
        }

        // Weekdays ("Friday", "next Friday", "until Friday").
        while let captures = consume("\\b(?:(from|to|until|through)\\s+)?(next\\s+|this\\s+)?(\(weekdayPattern))\\b", in: working) {
            let connector = captures[1]?.lowercased()
            let modifier = captures[2]?.trimmingCharacters(in: .whitespaces).lowercased()
            let numbers = weekdayNumbers(in: captures[3] ?? "")
            guard let weekday = numbers.first else { continue }
            var day = nextOccurrence(ofWeekday: weekday, from: today, calendar: calendar)
            if modifier == "next" { day = calendar.date(byAdding: .day, value: 7, to: day) ?? day }
            record(
                day,
                precededByFrom: connector == "from",
                precededByTo: connector == "to" || connector == "until" || connector == "through"
            )
            result.weekdays.append(weekday)
        }

        return result
    }

    private static func monthNameDate(month: String?, day: String?, year: String?, reference: Date, calendar: Calendar) -> Date? {
        guard let monthText = month?.lowercased().replacingOccurrences(of: ".", with: ""),
              let dayNumber = Int(day ?? "") else { return nil }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        guard let monthNumber = months[String(monthText.prefix(3))] else { return nil }
        return date(month: monthNumber, day: dayNumber, year: Int(year ?? ""), reference: reference, calendar: calendar)
    }

    private static func numericDate(month: String?, day: String?, year: String?, reference: Date, calendar: Calendar) -> Date? {
        guard let monthNumber = Int(month ?? ""), let dayNumber = Int(day ?? ""),
              (1...12).contains(monthNumber), (1...31).contains(dayNumber) else { return nil }
        var yearNumber = Int(year ?? "")
        if let short = yearNumber, year?.count == 2 { yearNumber = 2000 + short }
        return date(month: monthNumber, day: dayNumber, year: yearNumber, reference: reference, calendar: calendar)
    }

    /// Foundation normalizes impossible dates (February 30 becomes March 2).
    /// Compare components so invalid input cannot silently create another day.
    private static func checkedDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day ? date : nil
    }

    private static func date(month: Int, day: Int, year: Int?, reference: Date, calendar: Calendar) -> Date? {
        if let year { return checkedDate(year: year, month: month, day: day, calendar: calendar) }
        let currentYear = calendar.component(.year, from: reference)
        guard (1...9999).contains(currentYear) else { return nil }
        let today = calendar.startOfDay(for: reference)
        // Include the next leap day when the current year has no February 29.
        for year in currentYear...min(currentYear + 8, 9999) {
            if let candidate = checkedDate(year: year, month: month, day: day, calendar: calendar), candidate >= today {
                return candidate
            }
        }
        return nil
    }

    private static func nextOccurrence(ofWeekday weekday: Int, from day: Date, calendar: Calendar) -> Date {
        let current = calendar.component(.weekday, from: day)
        let ahead = (weekday - current + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: day) ?? day
    }

    // MARK: - Resolution

    private static func resolve(
        into draft: inout ItemDraft,
        dates: ParsedDates,
        startTime: (hour: Int, minute: Int)?,
        endTime: (hour: Int, minute: Int)?,
        recurrence: inout RecurrenceDraft?,
        reference: Date,
        calendar: Calendar
    ) {
        let today = calendar.startOfDay(for: reference)
        var day = dates.first
        var spanEnd = dates.second

        // A lone "until <date>" is an end bound, not a start: it closes a
        // recurrence, or spans today..that day for a plain event.
        if spanEnd == nil, dates.firstIsEndBound, let bound = dates.first {
            if recurrence != nil {
                recurrence?.endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: bound))
                day = nil
            } else if startTime == nil, draft.kind == .event {
                day = today
                spanEnd = bound
            }
        }

        // "on the 15th": next occurrence of that day of month (or the recurrence anchor).
        if day == nil, let target = dates.dayOfMonth {
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: reference)) ?? today
            for offset in 0...12 {
                guard let month = calendar.date(byAdding: .month, value: offset, to: monthStart) else { continue }
                let parts = calendar.dateComponents([.year, .month], from: month)
                if let year = parts.year, let month = parts.month,
                   let candidate = checkedDate(year: year, month: month, day: target, calendar: calendar), candidate >= today {
                    day = candidate
                    break
                }
            }
        }

        // A weekly rule without an explicit date anchors on the nearest listed weekday.
        if day == nil, let weekdays = recurrence?.weekdays, !weekdays.isEmpty {
            day = weekdays
                .map { nextOccurrence(ofWeekday: $0, from: today, calendar: calendar) }
                .min()
        }

        draft.hasExplicitDate = day != nil

        // Repair inverted spans before applying them: weekday pairs wrap to the
        // following week ("Monday through Friday" on a Wednesday), and month
        // dates bumped into next year come back ("from Dec 28 to Jan 3" on Dec 30).
        if let start = day, var end = spanEnd, end < start {
            if dates.weekdays.count >= 2 {
                end = calendar.date(byAdding: .day, value: 7, to: end) ?? end
            } else if let backAYear = calendar.date(byAdding: .year, value: -1, to: start), backAYear <= end {
                day = backAYear
            } else {
                day = end
                end = start
            }
            spanEnd = end
        }

        // Span: recurrence end when repeating, else a multi-day all-day event.
        if let end = spanEnd {
            if recurrence != nil {
                recurrence?.endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
            } else if startTime == nil {
                draft.isAllDay = true
                draft.hasExplicitAllDay = true
                draft.endDay = calendar.startOfDay(for: end)
            }
        }

        if let time = startTime {
            // Time without a date: today if still ahead, else tomorrow.
            if day == nil {
                let candidate = dateBySetting(time: time, on: today, calendar: calendar)
                day = candidate > reference ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            }
            let resolvedDay = day ?? today
            let start = dateBySetting(time: time, on: resolvedDay, calendar: calendar)
            draft.start = start
            draft.hasTime = true
            if let end = endTime {
                draft.end = dateBySetting(time: end, on: resolvedDay, calendar: calendar)
            }
        } else if let day {
            draft.start = calendar.startOfDay(for: day)
            if draft.kind == .event, draft.endDay == nil { draft.isAllDay = true }
        }
    }

    /// Builds a concrete instant, tolerating hour values >= 24 (midnight-crossing ranges).
    private static func dateBySetting(time: (hour: Int, minute: Int), on day: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        if time.hour >= 24 {
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            return calendar.date(bySettingHour: time.hour - 24, minute: time.minute, second: 0, of: next) ?? next
        }
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: dayStart) ?? dayStart
    }

    private static func apply(meridiem: String?, to raw: (h: Int, m: Int)) -> (hour: Int, minute: Int) {
        var hour = raw.h
        switch meridiem {
        case "pm" where hour < 12: hour += 12
        case "am" where hour == 12: hour = 0
        default: break
        }
        return (hour, raw.m)
    }

    private static func validClock(_ raw: (h: Int, m: Int), meridiem: String? = nil) -> Bool {
        (0...59).contains(raw.m) && (meridiem == nil ? (0...23).contains(raw.h) : (1...12).contains(raw.h))
    }

    /// "at 8" with no meridiem: 1-6 reads as evening, 7-12 as morning, 13+ as 24h.
    private static func daytimeGuess(hour: Int) -> (hour: Int, minute: Int) {
        switch hour {
        case 1...6: (hour + 12, 0)
        case 12: (12, 0)
        default: (hour, 0)
        }
    }

    private static func minutes(_ time: (hour: Int, minute: Int)) -> Int { time.hour * 60 + time.minute }

    // MARK: - Title assembly

    private static let connectors: Set<String> = [
        "on", "at", "from", "to", "by", "until", "through", "in", "the",
        "this", "next", "starting", "for", "and",
    ]

    private static func buildTitle(from leftover: String, quoted: [String]) -> String {
        // Consumed tokens left runs of spaces behind; treat 2+ spaces as segment seams
        // and strip connector words dangling at segment edges ("Dentist on", "by").
        var segments: [String] = []
        for rawSegment in leftover.components(separatedBy: "  ") {
            var words = rawSegment.split(separator: " ").map(String.init)
            while let first = words.first, connectors.contains(first.lowercased()) { words.removeFirst() }
            while let last = words.last, connectors.contains(last.lowercased()) { words.removeLast() }
            if !words.isEmpty { segments.append(words.joined(separator: " ")) }
        }
        return restoreQuotes(segments.joined(separator: " "), quoted: quoted)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces each run of a quote-sentinel character (U+E000+i) with the i-th
    /// quoted string, restoring quotes at their original positions.
    private static func restoreQuotes(_ text: String, quoted: [String]) -> String {
        guard !quoted.isEmpty else { return text }
        var result = ""
        var lastIndex: Int? = nil
        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            if (0xE000...0xE0FF).contains(value) {
                let index = value - 0xE000
                if lastIndex != index {
                    if index < quoted.count { result += quoted[index] }
                    lastIndex = index
                }
            } else {
                lastIndex = nil
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Regex plumbing

    /// Finds the first case-insensitive match, blanks it with spaces, and returns
    /// its capture groups (index 0 = whole match). Returns nil when unmatched.
    private static func consume(_ pattern: String, in working: NSMutableString) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            assertionFailure("Bad pattern: \(pattern)")
            return nil
        }
        let range = NSRange(location: 0, length: working.length)
        guard let match = regex.firstMatch(in: working as String, options: [], range: range) else { return nil }
        var captures: [String?] = []
        for index in 0..<match.numberOfRanges {
            let groupRange = match.range(at: index)
            captures.append(groupRange.location == NSNotFound ? nil : working.substring(with: groupRange))
        }
        working.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        return captures
    }

    /// Finds the first match's whole range without consuming it.
    private static func firstRange(_ pattern: String, in working: NSMutableString) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: working.length)
        return regex.firstMatch(in: working as String, options: [], range: range)?.range
    }
}

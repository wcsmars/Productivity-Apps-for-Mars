import EventKit
import SwiftUI

/// Bridges EventKit (calendar events + reminders) into value models the views
/// render. In demo mode (`-seedDemoData`) it serves deterministic in-memory
/// data instead, so UI verification never trips permission alerts.
@MainActor
final class CalendarStore: ObservableObject {
    enum AccessState { case notDetermined, authorized, denied }

    @Published private(set) var eventAccess: AccessState = .notDetermined
    @Published private(set) var reminderAccess: AccessState = .notDetermined
    @Published private(set) var calendars: [CalendarSource] = []
    @Published private(set) var taskLists: [CalendarSource] = []
    /// Events in the fetch window from visible calendars, sorted by start.
    @Published private(set) var events: [EventItem] = []
    /// Tasks from visible lists: all incomplete plus recently completed, due-date sorted (undated last).
    @Published private(set) var tasks: [TaskItem] = []
    @Published var mutationError: String?
    @Published private(set) var hiddenCalendarIDs: Set<String>
    /// Fantastical-style Calendar Sets: named visibility groups.
    @Published private(set) var calendarSets: [CalendarSet] = []
    @Published private(set) var activeSetID: UUID?

    @Published var defaultDurationMinutes: Int {
        didSet { defaults.set(defaultDurationMinutes, forKey: "defaultDurationMinutes") }
    }
    @Published var defaultCalendarID: String? {
        didSet { defaults.set(defaultCalendarID, forKey: "defaultCalendarID") }
    }
    @Published var hideCompleted: Bool {
        didSet {
            defaults.set(hideCompleted, forKey: "hideCompleted")
            refresh()
        }
    }

    let isDemo: Bool
    private(set) var windowStart: Date
    private(set) var windowEnd: Date

    private let ekStore = EKEventStore()
    private let calendar = Calendar.current
    private let defaults = UserDefaults.standard
    /// Occurrence id -> live EKEvent from the last fetch, for edits/deletes.
    private var ekEventsByOccurrence: [String: EKEvent] = [:]
    private var ekRemindersByID: [String: EKReminder] = [:]
    private var reminderFetchGeneration = 0
    /// Demo-mode backing arrays (all calendars, unfiltered).
    private var demoEvents: [EventItem] = []
    private var demoTasks: [TaskItem] = []

    init(demo: Bool = false) {
        isDemo = demo
        let today = Calendar.current.startOfDay(for: .now)
        windowStart = Calendar.current.date(byAdding: .day, value: -365, to: today)!
        windowEnd = Calendar.current.date(byAdding: .day, value: 550, to: today)!
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        if let data = defaults.data(forKey: "calendarSets"),
           let sets = try? JSONDecoder().decode([CalendarSet].self, from: data) {
            calendarSets = sets
        }
        activeSetID = defaults.string(forKey: "activeCalendarSetID").flatMap(UUID.init)
        let storedDuration = defaults.integer(forKey: "defaultDurationMinutes")
        defaultDurationMinutes = storedDuration == 0 ? 60 : storedDuration
        defaultCalendarID = defaults.string(forKey: "defaultCalendarID")
        hideCompleted = defaults.bool(forKey: "hideCompleted")

        if demo {
            eventAccess = .authorized
            reminderAccess = .authorized
            #if DEBUG
            seedDemoData()
            #endif
            rebuildFromDemo()
        } else {
            readAccessStates()
            if eventAccess == .authorized || reminderAccess == .authorized { refresh() }
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: ekStore, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    // MARK: - Access

    var hasAnyAccess: Bool { eventAccess == .authorized || reminderAccess == .authorized }

    private func readAccessStates() {
        eventAccess = Self.state(for: EKEventStore.authorizationStatus(for: .event))
        reminderAccess = Self.state(for: EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func state(for status: EKAuthorizationStatus) -> AccessState {
        switch status {
        case .fullAccess: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Requests full access to events and reminders (no-op in demo mode).
    func requestAccess() async {
        guard !isDemo else { return }
        _ = try? await ekStore.requestFullAccessToEvents()
        _ = try? await ekStore.requestFullAccessToReminders()
        readAccessStates()
        refresh()
    }

    // MARK: - Fetching

    func refresh() {
        if isDemo {
            rebuildFromDemo()
            return
        }
        // Permissions can change in Settings while the app is in the background.
        readAccessStates()
        if eventAccess == .authorized {
            fetchCalendarsAndEvents()
        } else {
            calendars = []
            events = []
            ekEventsByOccurrence = [:]
        }
        if reminderAccess == .authorized {
            fetchListsAndReminders()
        } else {
            reminderFetchGeneration += 1
            taskLists = []
            tasks = []
            ekRemindersByID = [:]
        }
    }

    /// Expands the fetch window (in half-year steps) when navigation leaves it.
    func ensureWindowContains(_ day: Date) {
        var changed = false
        while day < windowStart {
            windowStart = calendar.date(byAdding: .month, value: -6, to: windowStart)!
            changed = true
        }
        while day >= windowEnd {
            windowEnd = calendar.date(byAdding: .month, value: 6, to: windowEnd)!
            changed = true
        }
        // EventKit's event predicate silently truncates spans over four years;
        // keep the window well under that by pulling the far edge toward the target.
        if changed,
           let span = calendar.dateComponents([.day], from: windowStart, to: windowEnd).day,
           span > 1300 {
            if windowEnd.timeIntervalSince(day) < day.timeIntervalSince(windowStart) {
                windowStart = calendar.date(byAdding: .day, value: -650, to: day)!
            } else {
                windowEnd = calendar.date(byAdding: .day, value: 650, to: day)!
            }
        }
        if changed { refresh() }
    }

    private func fetchCalendarsAndEvents() {
        let ekCalendars = ekStore.calendars(for: .event)
        calendars = ekCalendars
            .map { Self.source(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let visible = ekCalendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else {
            events = []
            ekEventsByOccurrence = [:]
            return
        }
        let predicate = ekStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: visible)
        let ekEvents = ekStore.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }
        var mapped: [EventItem] = []
        var byOccurrence: [String: EKEvent] = [:]
        for ekEvent in ekEvents {
            guard let item = Self.item(from: ekEvent, calendar: calendar) else { continue }
            mapped.append(item)
            byOccurrence[item.id] = ekEvent
        }
        events = mapped
        ekEventsByOccurrence = byOccurrence
    }

    private func fetchListsAndReminders() {
        // Invalidate older requests even when every list is now hidden.
        reminderFetchGeneration += 1
        let generation = reminderFetchGeneration
        let ekLists = ekStore.calendars(for: .reminder)
        taskLists = ekLists
            .map { Self.source(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let visible = ekLists.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else {
            tasks = []
            ekRemindersByID = [:]
            return
        }

        let incomplete = ekStore.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: visible
        )
        let completed = ekStore.predicateForCompletedReminders(
            withCompletionDateStarting: windowStart, ending: .distantFuture, calendars: visible
        )
        // Generation guard: overlapping fetches resolve out of order, and a stale
        // result landing last would revert fresh state (e.g. un-complete a task).
        Task { [weak self] in
            let incompleteReminders = await Self.fetch(matching: incomplete, from: self?.ekStore)
            let completedReminders = self?.hideCompleted == true
                ? []
                : await Self.fetch(matching: completed, from: self?.ekStore)
            await MainActor.run {
                guard let self, generation == self.reminderFetchGeneration else { return }
                var byID: [String: EKReminder] = [:]
                var mapped: [TaskItem] = []
                for reminder in incompleteReminders + completedReminders {
                    guard let item = Self.item(from: reminder, calendar: self.calendar) else { continue }
                    mapped.append(item)
                    byID[item.id] = reminder
                }
                self.tasks = Self.sortTasks(mapped)
                self.ekRemindersByID = byID
            }
        }
    }

    private static func fetch(matching predicate: NSPredicate, from store: EKEventStore?) async -> [EKReminder] {
        guard let store else { return [] }
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private static func sortTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted {
            switch ($0.due, $1.due) {
            case let (first?, second?): first < second
            case (nil, _?): false
            case (_?, nil): true
            default: $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    // MARK: - Mapping

    private static func source(from ekCalendar: EKCalendar) -> CalendarSource {
        CalendarSource(
            id: ekCalendar.calendarIdentifier,
            title: ekCalendar.title,
            color: ekCalendar.cgColor.map { Color(cgColor: $0) } ?? Theme.wine,
            allowsModifications: ekCalendar.allowsContentModifications
        )
    }

    private static func item(from ekEvent: EKEvent, calendar: Calendar) -> EventItem? {
        guard let start = ekEvent.startDate, var end = ekEvent.endDate else { return nil }
        // EventKit all-day events end WITHIN their last day (23:59:59); the app
        // uses exclusive midnight-after ends everywhere, so normalize here.
        if ekEvent.isAllDay {
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        }
        let eventID = ekEvent.eventIdentifier ?? UUID().uuidString
        let alarmMinutes = ekEvent.alarms?
            .compactMap { $0.absoluteDate == nil ? Int(-$0.relativeOffset / 60) : nil }
            .first
        let attendees: [Attendee] = (ekEvent.attendees ?? []).compactMap { participant in
            guard participant.participantType == .person || participant.participantType == .group else { return nil }
            let status: Attendee.Status = switch participant.participantStatus {
            case .accepted: .accepted
            case .declined: .declined
            case .tentative: .tentative
            case .pending: .pending
            default: .unknown
            }
            return Attendee(
                name: participant.name ?? "Invitee",
                status: status,
                isOrganizer: participant.participantRole == .chair
            )
        }
        let deviceZone = TimeZone.current.identifier
        return EventItem(
            id: "\(eventID)#\(start.timeIntervalSinceReferenceDate)",
            eventID: eventID,
            title: ekEvent.title ?? "Untitled",
            start: start,
            end: end,
            isAllDay: ekEvent.isAllDay,
            calendarID: ekEvent.calendar?.calendarIdentifier ?? "",
            location: ekEvent.location?.isEmpty == false ? ekEvent.location : nil,
            notes: ekEvent.notes?.isEmpty == false ? ekEvent.notes : nil,
            hasRecurrence: ekEvent.hasRecurrenceRules,
            recurrenceText: ekEvent.recurrenceRules?.first.map(Self.describe),
            alertMinutesBefore: alarmMinutes,
            attendees: attendees,
            url: ekEvent.url,
            timeZoneID: ekEvent.timeZone.flatMap { $0.identifier == deviceZone ? nil : $0.identifier }
        )
    }

    private static func item(from reminder: EKReminder, calendar: Calendar) -> TaskItem? {
        var due: Date?
        var hasDueTime = false
        if let components = reminder.dueDateComponents {
            due = calendar.date(from: components)
            hasDueTime = components.hour != nil
        }
        let priority: Int = switch reminder.priority {
        case 1...4: 3
        case 5: 2
        case 6...9: 1
        default: 0
        }
        return TaskItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled",
            due: due,
            hasDueTime: hasDueTime,
            isCompleted: reminder.isCompleted,
            priority: priority,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            notes: reminder.notes?.isEmpty == false ? reminder.notes : nil,
            hasRecurrence: reminder.hasRecurrenceRules
        )
    }

    private static func describe(_ rule: EKRecurrenceRule) -> String {
        let unit: String = switch rule.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        default: "year"
        }
        return rule.interval > 1 ? "Repeats every \(rule.interval) \(unit)s" : "Repeats every \(unit)"
    }

    // MARK: - Queries

    func calendarSource(_ id: String) -> CalendarSource? {
        calendars.first { $0.id == id } ?? taskLists.first { $0.id == id }
    }

    func color(for calendarID: String) -> Color {
        calendarSource(calendarID)?.color ?? Theme.wine
    }

    var writableCalendars: [CalendarSource] { calendars.filter(\.allowsModifications) }

    /// The calendar new events land in: the setting, else the system default, else the first writable.
    var defaultCalendar: CalendarSource? {
        if let id = defaultCalendarID, let source = calendars.first(where: { $0.id == id }) { return source }
        if !isDemo, let system = ekStore.defaultCalendarForNewEvents {
            return calendars.first { $0.id == system.calendarIdentifier }
        }
        return writableCalendars.first ?? calendars.first
    }

    /// The list new tasks land in: the system default resolved to a source, else the first list.
    var defaultTaskList: CalendarSource? {
        if !isDemo, let system = ekStore.defaultCalendarForNewReminders(),
           let source = taskLists.first(where: { $0.id == system.calendarIdentifier }) {
            return source
        }
        return taskLists.first
    }

    // MARK: - Accounts & calendar creation

    /// Accounts new calendars can be created in (iCloud, Google/CalDAV, Exchange, local).
    /// Google and other external accounts appear here automatically once added to
    /// the device — that is how EventKit surfaces them.
    func accountSources(forReminders: Bool) -> [AccountSource] {
        if isDemo {
            return [AccountSource(id: "demo.icloud", title: "iCloud", kind: "iCloud")]
        }
        return ekStore.sources
            .filter { !$0.calendars(for: forReminders ? .reminder : .event).isEmpty || $0.sourceType == .local || $0.sourceType == .calDAV }
            .map { source in
                let kind: String = switch source.sourceType {
                case .calDAV: source.title.localizedCaseInsensitiveContains("icloud") ? "iCloud" : "CalDAV"
                case .exchange: "Exchange"
                case .local: "On this device"
                case .subscribed: "Subscribed"
                case .birthdays: "Birthdays"
                default: "Account"
                }
                return AccountSource(id: source.sourceIdentifier, title: source.title, kind: kind)
            }
            .filter { $0.kind != "Subscribed" && $0.kind != "Birthdays" }
    }

    /// Creates a calendar (or reminder list) in the given account.
    /// Returns nil on success, or a human-readable error.
    @discardableResult
    func createCalendar(named name: String, color: Color, sourceID: String, forReminders: Bool) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Give the calendar a name first." }

        if isDemo {
            let source = CalendarSource(id: "demo.custom.\(trimmed)", title: trimmed, color: color, allowsModifications: true)
            if forReminders { taskLists.append(source) } else { calendars.append(source) }
            return nil
        }

        guard let ekSource = ekStore.sources.first(where: { $0.sourceIdentifier == sourceID }) else {
            return "That account is no longer available."
        }
        let ekCalendar = EKCalendar(for: forReminders ? .reminder : .event, eventStore: ekStore)
        ekCalendar.title = trimmed
        ekCalendar.source = ekSource
        ekCalendar.cgColor = color.resolve(in: EnvironmentValues()).cgColor
        do {
            try ekStore.saveCalendar(ekCalendar, commit: true)
            refresh()
            return nil
        } catch {
            return "Couldn't create it there — some accounts (including many Google setups) only allow new calendars from their own website. (\(error.localizedDescription))"
        }
    }

    // MARK: - Calendar Sets

    /// The set currently applied, if visibility hasn't been hand-tweaked since.
    var activeSet: CalendarSet? {
        guard let activeSetID else { return nil }
        return calendarSets.first { $0.id == activeSetID }
    }

    private var allSourceIDs: Set<String> {
        Set(calendars.map(\.id)).union(taskLists.map(\.id))
    }

    func activateSet(_ set: CalendarSet) {
        activeSetID = set.id
        defaults.set(set.id.uuidString, forKey: "activeCalendarSetID")
        hiddenCalendarIDs = allSourceIDs.subtracting(set.visibleIDs)
        defaults.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs")
        refresh()
    }

    /// Shows everything again (the implicit "All Calendars" set).
    func activateAllCalendars() {
        activeSetID = nil
        defaults.removeObject(forKey: "activeCalendarSetID")
        hiddenCalendarIDs = []
        defaults.set([String](), forKey: "hiddenCalendarIDs")
        refresh()
    }

    /// Saves the CURRENT visibility as a named set and activates it.
    func saveCurrentAsSet(named name: String) {
        let set = CalendarSet(name: name, visibleIDs: allSourceIDs.subtracting(hiddenCalendarIDs))
        calendarSets.append(set)
        persistSets()
        activateSet(set)
    }

    func deleteSet(_ set: CalendarSet) {
        calendarSets.removeAll { $0.id == set.id }
        persistSets()
        if activeSetID == set.id {
            activeSetID = nil
            defaults.removeObject(forKey: "activeCalendarSetID")
        }
    }

    private func persistSets() {
        if let data = try? JSONEncoder().encode(calendarSets) {
            defaults.set(data, forKey: "calendarSets")
        }
    }

    func events(on day: Date) -> [EventItem] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
    }

    /// Incomplete-first tasks due on the given day (completed included per setting).
    func tasks(on day: Date) -> [TaskItem] {
        tasks.filter { task in
            guard let due = task.due else { return false }
            if hideCompleted && task.isCompleted { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
    }

    var undatedTasks: [TaskItem] {
        tasks.filter { $0.due == nil && !(hideCompleted && $0.isCompleted) }
    }

    /// Incomplete tasks whose due date is before today.
    var overdueTasks: [TaskItem] {
        let today = calendar.startOfDay(for: .now)
        return tasks.filter { task in
            guard let due = task.due, !task.isCompleted else { return false }
            return due < today
        }
    }

    /// Up to `limit` calendar colors for a day's items — ticker and month-grid dots.
    func dayDots(on day: Date, limit: Int = 3) -> [Color] {
        var colors: [Color] = []
        for event in events(on: day) {
            colors.append(color(for: event.calendarID))
            if colors.count == limit { return colors }
        }
        for task in tasks(on: day) where !task.isCompleted {
            colors.append(color(for: task.listID))
            if colors.count == limit { return colors }
        }
        return colors
    }

    /// Start-of-day keys for every day in the range with at least one event or task.
    func days(withItemsFrom start: Date, to end: Date) -> Set<Date> {
        var result: Set<Date> = []
        for event in events where event.end > start && event.start < end {
            var day = calendar.startOfDay(for: max(event.start, start))
            let last = min(event.end, end)
            while day < last {
                result.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for task in tasks {
            guard let due = task.due, due >= start, due < end else { continue }
            if hideCompleted && task.isCompleted { continue }
            result.insert(calendar.startOfDay(for: due))
        }
        return result
    }

    func searchItems(matching query: String) -> (events: [EventItem], tasks: [TaskItem]) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return ([], []) }
        func matches(_ candidates: String?...) -> Bool {
            candidates.contains { $0?.localizedCaseInsensitiveContains(needle) == true }
        }
        return (
            events.filter { matches($0.title, $0.location, $0.notes) },
            tasks.filter { matches($0.title, $0.notes) }
        )
    }

    // MARK: - Visibility

    func setCalendar(_ id: String, hidden: Bool) {
        if hidden { hiddenCalendarIDs.insert(id) } else { hiddenCalendarIDs.remove(id) }
        defaults.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs")
        // Hand-tweaked visibility is a custom state, not the active set anymore.
        activeSetID = nil
        defaults.removeObject(forKey: "activeCalendarSetID")
        refresh()
    }

    // MARK: - Mutations

    /// Creates an event or task from a quick-add draft. Returns false on failure.
    @discardableResult
    func createItem(from draft: ItemDraft) -> Bool {
        guard draft.validationErrors.isEmpty else { return false }
        return switch draft.kind {
        case .event: createEvent(from: draft)
        case .task: createTask(from: draft)
        }
    }

    private func resolvedTimes(for draft: ItemDraft) -> (start: Date, end: Date, allDay: Bool) {
        let today = calendar.startOfDay(for: .now)
        let start = draft.start ?? today
        if draft.isAllDay || !draft.hasTime {
            let endDay = draft.endDay ?? calendar.startOfDay(for: start)
            return (calendar.startOfDay(for: start), endDay, true)
        }
        let minutes = draft.durationMinutes ?? defaultDurationMinutes
        let end = draft.end ?? start.addingTimeInterval(TimeInterval(minutes * 60))
        return (start, end, false)
    }

    private func createEvent(from draft: ItemDraft) -> Bool {
        let times = resolvedTimes(for: draft)
        let title = draft.title.isEmpty ? "New Event" : draft.title

        if isDemo {
            let calendarID = draft.calendarID ?? defaultCalendar?.id ?? ""
            let eventID = UUID().uuidString
            let end = times.allDay
                ? calendar.date(byAdding: .day, value: 1, to: times.end) ?? times.end
                : times.end
            demoEvents.append(EventItem(
                id: "\(eventID)#\(times.start.timeIntervalSinceReferenceDate)",
                eventID: eventID, title: title, start: times.start, end: end,
                isAllDay: times.allDay, calendarID: calendarID,
                location: draft.location, notes: draft.notes,
                hasRecurrence: draft.recurrence != nil,
                recurrenceText: draft.recurrence?.text,
                alertMinutesBefore: draft.alertMinutesBefore
            ))
            rebuildFromDemo()
            return true
        }

        let ekEvent = EKEvent(eventStore: ekStore)
        ekEvent.title = title
        ekEvent.isAllDay = times.allDay
        ekEvent.startDate = times.start
        ekEvent.endDate = times.end
        ekEvent.location = draft.location
        ekEvent.notes = draft.notes
        if let id = draft.calendarID ?? defaultCalendar?.id,
           let ekCalendar = ekStore.calendar(withIdentifier: id) {
            ekEvent.calendar = ekCalendar
        } else {
            ekEvent.calendar = ekStore.defaultCalendarForNewEvents
        }
        if let minutes = draft.alertMinutesBefore {
            ekEvent.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        if let rule = Self.rule(from: draft.recurrence) {
            ekEvent.addRecurrenceRule(rule)
        }
        do {
            try ekStore.save(ekEvent, span: .futureEvents)
            refresh()
            return true
        } catch {
            return false
        }
    }

    private func createTask(from draft: ItemDraft) -> Bool {
        var draft = draft
        let title = draft.title.isEmpty ? "New Task" : draft.title
        // EventKit refuses recurring reminders without a due date — anchor on today.
        if draft.recurrence != nil, draft.start == nil {
            draft.start = calendar.startOfDay(for: .now)
        }

        if isDemo {
            demoTasks.append(TaskItem(
                id: UUID().uuidString, title: title, due: draft.start,
                hasDueTime: draft.hasTime, isCompleted: false, priority: draft.priority,
                listID: draft.calendarID ?? taskLists.first?.id ?? "",
                notes: draft.notes, hasRecurrence: draft.recurrence != nil
            ))
            rebuildFromDemo()
            return true
        }

        let reminder = EKReminder(eventStore: ekStore)
        reminder.title = title
        reminder.notes = draft.notes
        if let id = draft.calendarID, let list = ekStore.calendar(withIdentifier: id), list.allowedEntityTypes.contains(.reminder) {
            reminder.calendar = list
        } else if let fallback = ekStore.defaultCalendarForNewReminders()
            ?? ekStore.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) {
            reminder.calendar = fallback
        }
        if let due = draft.start {
            var components: Set<Calendar.Component> = [.year, .month, .day]
            if draft.hasTime { components.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = calendar.dateComponents(components, from: due)
            if let minutes = draft.alertMinutesBefore {
                reminder.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(TimeInterval(-minutes * 60))))
            }
        }
        reminder.priority = switch draft.priority {
        case 3: 1
        case 2: 5
        case 1: 9
        default: 0
        }
        if let rule = Self.rule(from: draft.recurrence) {
            reminder.addRecurrenceRule(rule)
        }
        do {
            try ekStore.save(reminder, commit: true)
            refresh()
            return true
        } catch {
            return false
        }
    }

    private static func rule(from draft: RecurrenceDraft?) -> EKRecurrenceRule? {
        guard let draft else { return nil }
        let frequency: EKRecurrenceFrequency = switch draft.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let days = draft.weekdays?.compactMap { number -> EKRecurrenceDayOfWeek? in
            EKWeekday(rawValue: number).map { EKRecurrenceDayOfWeek($0) }
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: max(1, draft.interval),
            daysOfTheWeek: days?.isEmpty == false ? days : nil,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil,
            end: draft.endDate.map { EKRecurrenceEnd(end: $0) }
        )
    }

    /// Applies edited fields of an occurrence back to EventKit (span: this event only).
    @discardableResult
    func save(event: EventItem) -> Bool {
        mutationError = nil
        if isDemo {
            if let index = demoEvents.firstIndex(where: { $0.id == event.id }) {
                demoEvents[index] = event
                rebuildFromDemo()
                return true
            }
            return mutationFailed("This event is no longer available. Reopen it and try again.")
        }
        guard let ekEvent = ekEventsByOccurrence[event.id] ?? staleFallback(for: event) else {
            return mutationFailed("This event changed or is no longer available. Reopen it and try again.")
        }
        ekEvent.title = event.title
        ekEvent.isAllDay = event.isAllDay
        ekEvent.startDate = event.start
        // The app's all-day ends are exclusive midnights; EventKit expects an
        // end within the last day.
        ekEvent.endDate = event.isAllDay
            ? calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.end
            : event.end
        ekEvent.location = event.location
        ekEvent.notes = event.notes
        if event.calendarID != ekEvent.calendar?.calendarIdentifier,
           let ekCalendar = ekStore.calendar(withIdentifier: event.calendarID) {
            ekEvent.calendar = ekCalendar
        }
        // Only rewrite alarms when the alert actually changed, so extra or
        // absolute-date alarms survive unrelated edits.
        let currentAlert = ekEvent.alarms?
            .compactMap { $0.absoluteDate == nil ? Int(-$0.relativeOffset / 60) : nil }
            .first
        if currentAlert != event.alertMinutesBefore {
            ekEvent.alarms = event.alertMinutesBefore.map {
                [EKAlarm(relativeOffset: TimeInterval(-$0 * 60))]
            }
        }
        do {
            try ekStore.save(ekEvent, span: .thisEvent)
        } catch {
            refresh()
            return mutationFailed("Couldn't save the event: \(error.localizedDescription)")
        }
        refresh()
        return true
    }

    /// Occurrence ids embed the start time, so an external change while a detail
    /// sheet is open orphans the id. For non-recurring events the plain
    /// identifier still names the same event unambiguously.
    private func staleFallback(for event: EventItem) -> EKEvent? {
        guard !event.hasRecurrence,
              let ekEvent = ekStore.event(withIdentifier: event.eventID),
              !ekEvent.hasRecurrenceRules else { return nil }
        return ekEvent
    }

    @discardableResult
    func delete(event: EventItem, futureOccurrences: Bool = false) -> Bool {
        mutationError = nil
        if isDemo {
            if futureOccurrences {
                demoEvents.removeAll { $0.eventID == event.eventID && $0.start >= event.start }
            } else {
                demoEvents.removeAll { $0.id == event.id }
            }
            rebuildFromDemo()
            return true
        }
        guard let ekEvent = ekEventsByOccurrence[event.id] ?? staleFallback(for: event) else {
            return mutationFailed("This event changed or is no longer available. Reopen it and try again.")
        }
        do {
            try ekStore.remove(ekEvent, span: futureOccurrences ? .futureEvents : .thisEvent)
        } catch {
            refresh()
            return mutationFailed("Couldn't delete the event: \(error.localizedDescription)")
        }
        refresh()
        return true
    }

    @discardableResult
    func save(task: TaskItem) -> Bool {
        mutationError = nil
        if isDemo {
            if let index = demoTasks.firstIndex(where: { $0.id == task.id }) {
                demoTasks[index] = task
                rebuildFromDemo()
                return true
            }
            return mutationFailed("This task is no longer available. Reopen it and try again.")
        }
        guard let reminder = ekRemindersByID[task.id] else {
            return mutationFailed("This task changed or is no longer available. Reopen it and try again.")
        }
        reminder.title = task.title
        reminder.notes = task.notes
        let previousDue = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
        if let due = task.due {
            var components: Set<Calendar.Component> = [.year, .month, .day]
            if task.hasDueTime { components.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = calendar.dateComponents(components, from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        // A moved or cleared due date orphans absolute-date alarms — drop them
        // so a rescheduled task can't keep firing at the old time.
        if previousDue != task.due {
            reminder.alarms = reminder.alarms?.filter { $0.absoluteDate == nil }
        }
        reminder.priority = switch task.priority {
        case 3: 1
        case 2: 5
        case 1: 9
        default: 0
        }
        reminder.isCompleted = task.isCompleted
        let movedList = task.listID != reminder.calendar?.calendarIdentifier
        if movedList, let list = ekStore.calendar(withIdentifier: task.listID) {
            reminder.calendar = list
        }
        do {
            try ekStore.save(reminder, commit: true)
        } catch {
            refresh()
            return mutationFailed("Couldn't save the task: \(error.localizedDescription)")
        }
        // Moving lists can re-issue the reminder's identifier — tell listeners
        // (the dashboard's matrix placements) so per-task state can re-key.
        if movedList, reminder.calendarItemIdentifier != task.id {
            NotificationCenter.default.post(
                name: .taskIdentifierDidChange, object: nil,
                userInfo: ["old": task.id, "new": reminder.calendarItemIdentifier]
            )
        }
        refresh()
        return true
    }

    @discardableResult
    func toggleCompleted(_ task: TaskItem) -> Bool {
        var updated = task
        updated.isCompleted.toggle()
        return save(task: updated)
    }

    @discardableResult
    func delete(task: TaskItem) -> Bool {
        mutationError = nil
        if isDemo {
            demoTasks.removeAll { $0.id == task.id }
            rebuildFromDemo()
            return true
        }
        guard let reminder = ekRemindersByID[task.id] else {
            return mutationFailed("This task changed or is no longer available. Reopen it and try again.")
        }
        do {
            try ekStore.remove(reminder, commit: true)
        } catch {
            refresh()
            return mutationFailed("Couldn't delete the task: \(error.localizedDescription)")
        }
        refresh()
        return true
    }

    private func mutationFailed(_ message: String) -> Bool {
        mutationError = message
        return false
    }

    // MARK: - Demo plumbing

    private func rebuildFromDemo() {
        events = demoEvents
            .filter { !hiddenCalendarIDs.contains($0.calendarID) }
            .sorted { $0.start < $1.start }
        tasks = Self.sortTasks(demoTasks.filter {
            !hiddenCalendarIDs.contains($0.listID) && !(hideCompleted && $0.isCompleted)
        })
    }

    #if DEBUG
    /// Deterministic sample data relative to today: four wine-family calendars,
    /// two task lists, ~5 months of events, and a handful of tasks.
    private func seedDemoData() {
        let plum = Color(red: 142 / 255, green: 74 / 255, blue: 99 / 255)
        calendars = [
            CalendarSource(id: "demo.family", title: "Family", color: plum, allowsModifications: true),
            CalendarSource(id: "demo.fitness", title: "Fitness", color: Theme.rose, allowsModifications: true),
            CalendarSource(id: "demo.personal", title: "Personal", color: Theme.wine, allowsModifications: true),
            CalendarSource(id: "demo.work", title: "Work", color: Theme.wineDeep, allowsModifications: true),
        ]
        taskLists = [
            CalendarSource(id: "demo.errands", title: "Errands", color: Theme.rose, allowsModifications: true),
            CalendarSource(id: "demo.reminders", title: "Reminders", color: Theme.wine, allowsModifications: true),
        ]
        if defaultCalendarID == nil { defaultCalendarID = "demo.personal" }

        var generator = SeededGenerator(seed: 42)
        let today = calendar.startOfDay(for: .now)

        func add(_ title: String, dayOffset: Int, minutes: Int, duration: Int,
                 calendarID: String, location: String? = nil,
                 recurring: String? = nil, alert: Int? = nil) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let start = calendar.time(atMinutes: minutes, on: day) else { return }
            let eventID = "demo-\(title)-\(dayOffset)"
            demoEvents.append(EventItem(
                id: "\(eventID)#\(start.timeIntervalSinceReferenceDate)",
                eventID: recurring != nil ? "demo-\(title)" : eventID,
                title: title, start: start,
                end: start.addingTimeInterval(TimeInterval(duration * 60)),
                isAllDay: false, calendarID: calendarID, location: location, notes: nil,
                hasRecurrence: recurring != nil, recurrenceText: recurring,
                alertMinutesBefore: alert
            ))
        }

        func addAllDay(_ title: String, dayOffset: Int, days: Int = 1, calendarID: String, recurring: String? = nil) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let end = calendar.date(byAdding: .day, value: days, to: day) else { return }
            let eventID = "demo-\(title)-\(dayOffset)"
            demoEvents.append(EventItem(
                id: "\(eventID)#\(day.timeIntervalSinceReferenceDate)",
                eventID: eventID, title: title, start: day, end: end,
                isAllDay: true, calendarID: calendarID, location: nil, notes: nil,
                hasRecurrence: recurring != nil, recurrenceText: recurring, alertMinutesBefore: nil
            ))
        }

        for offset in -60...120 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekday = (2...6).contains(weekday)
            if isWeekday {
                add("Standup", dayOffset: offset, minutes: 9 * 60 + 30, duration: 15,
                    calendarID: "demo.work", recurring: "Repeats every weekday")
            }
            if weekday == 2 || weekday == 5 {
                add("Gym with Marcus", dayOffset: offset, minutes: 18 * 60, duration: 75,
                    calendarID: "demo.fitness", location: "Iron Temple",
                    recurring: "Repeats every Mon, Thu")
            }
            if isWeekday && Double.random(in: 0...1, using: &generator) < 0.35 {
                let starts = [11 * 60, 13 * 60, 14 * 60 + 30, 16 * 60]
                let titles = ["Design review", "1:1 with Sam", "Sprint planning", "Client call"]
                let index = Int.random(in: 0..<titles.count, using: &generator)
                add(titles[index], dayOffset: offset, minutes: starts[index], duration: 45,
                    calendarID: "demo.work")
            }
            if Double.random(in: 0...1, using: &generator) < 0.18 {
                let picks = [
                    ("Lunch with Alex", 12 * 60 + 30, 60, "Cafe Rio"),
                    ("Coffee with Shawn", 8 * 60, 45, "Bluebird Coffee"),
                    ("Dinner with Mom", 19 * 60, 90, "Casa Toscana"),
                ]
                let pick = picks[Int.random(in: 0..<picks.count, using: &generator)]
                add(pick.0, dayOffset: offset, minutes: pick.1, duration: pick.2,
                    calendarID: "demo.personal", location: pick.3)
            }
        }
        add("Dentist", dayOffset: 3, minutes: 9 * 60, duration: 45,
            calendarID: "demo.personal", location: "Smile Studio", alert: 60)
        add("Flight to NYC", dayOffset: 12, minutes: 7 * 60 + 45, duration: 147,
            calendarID: "demo.personal", location: "SFO Terminal 2", alert: 120)
        add("Piano recital", dayOffset: 6, minutes: 17 * 60, duration: 90,
            calendarID: "demo.family", location: "Community Hall")
        addAllDay("Dad's birthday", dayOffset: 9, calendarID: "demo.family", recurring: "Repeats every year")
        addAllDay("Beach vacation", dayOffset: 30, days: 7, calendarID: "demo.family")
        addAllDay("Marathon day", dayOffset: 47, calendarID: "demo.fitness")

        func addTask(_ title: String, dayOffset: Int?, minutes: Int? = nil,
                     priority: Int = 0, listID: String = "demo.reminders",
                     completed: Bool = false, recurring: Bool = false) {
            var due: Date?
            if let dayOffset, let day = calendar.date(byAdding: .day, value: dayOffset, to: today) {
                due = minutes.flatMap { calendar.time(atMinutes: $0, on: day) } ?? day
            }
            demoTasks.append(TaskItem(
                id: "demo-task-\(title)", title: title, due: due,
                hasDueTime: minutes != nil, isCompleted: completed, priority: priority,
                listID: listID, notes: nil, hasRecurrence: recurring
            ))
        }
        addTask("Finish quarterly report", dayOffset: 1, priority: 3)
        addTask("Pay rent", dayOffset: 8, priority: 2, recurring: true)
        addTask("Pick up dry cleaning", dayOffset: 0, minutes: 17 * 60, listID: "demo.errands")
        addTask("Book flights for vacation", dayOffset: 5)
        addTask("Call plumber", dayOffset: -2, priority: 1, listID: "demo.errands")
        addTask("Renew passport", dayOffset: nil)
        addTask("Order birthday cake", dayOffset: 7, listID: "demo.errands")
        addTask("Water the plants", dayOffset: 0, completed: true)
    }
    #endif
}

#if DEBUG
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

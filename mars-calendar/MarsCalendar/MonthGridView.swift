import SwiftUI

/// How month-grid days render their contents.
private enum MonthDisplay: String {
    /// Compact 46pt cells with up to three calendar-colored dots.
    case dots
    /// Fantastical-style tall cells with event titles directly on the grid.
    case events
}

/// What one day cell shows, bucketed once per render for the whole window so
/// cells don't each rescan the store's full arrays.
private struct DayItems {
    var events: [EventItem] = []
    var tasks: [TaskItem] = []
}

/// Fantastical-style month mode: a paged grid in the suite's calendar pattern,
/// with the selected day's agenda listed beneath. Display options (dots vs
/// event titles, weeks shown, week numbers, weekend shading, tasks) live in
/// the ⋯ menu on the header and persist via AppStorage. This view is the
/// scrollable content — CalendarTabView drops it in below the ticker.
struct MonthGridView: View {
    @Binding var selectedDay: Date
    /// Set by CalendarTabView so a day's context menu can jump to Week view.
    var openWeek: ((Date) -> Void)? = nil

    @EnvironmentObject private var store: CalendarStore

    @AppStorage("monthDisplay") private var displayRaw = MonthDisplay.dots.rawValue
    /// 0 = the whole calendar month; 2/4/6/8 = a rolling window of that many weeks.
    @AppStorage("monthWeeks") private var weeksShown = 0
    @AppStorage("monthWeekNumbers") private var showsWeekNumbers = false
    @AppStorage("monthWeekendShading") private var shadesWeekends = false
    @AppStorage("monthShowsTasks") private var showsTasks = true

    @State private var displayedMonth: Date
    @State private var weekAnchor: Date
    @State private var today = Date.now
    @State private var selectedEvent: EventItem?
    @State private var selectedTask: TaskItem?
    @State private var quickAdd: QuickAddRequest?

    private let calendar = Calendar.current

    private struct QuickAddRequest: Identifiable {
        let id = UUID()
        let day: Date
        let kind: ItemDraft.Kind
    }

    init(selectedDay: Binding<Date>, openWeek: ((Date) -> Void)? = nil) {
        _selectedDay = selectedDay
        self.openWeek = openWeek
        let day = selectedDay.wrappedValue
        _displayedMonth = State(initialValue: Calendar.current.startOfMonth(for: day))
        _weekAnchor = State(initialValue: Calendar.current.dateInterval(of: .weekOfYear, for: day)?.start ?? day)
    }

    private var display: MonthDisplay { MonthDisplay(rawValue: displayRaw) ?? .dots }
    private var isRollingWeeks: Bool { weeksShown > 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                gridHeader
                weekdayHeader
                grid
                agendaSection
            }
            .padding()
            .padding(.bottom, 72) // keep the floating + clear of the last agenda rows
        }
        .background(Color.white)
        .onDayChange { today = .now }
        .onAppear { ensureWindowFetched() }
        .onChange(of: selectedDay) { _, newDay in
            ensureVisible(newDay)
        }
        .onChange(of: weeksShown) { _, _ in
            // Re-center the new window on the day the user was looking at.
            weekAnchor = calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
            displayedMonth = calendar.startOfMonth(for: selectedDay)
            ensureWindowFetched()
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailSheet(event: event)
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailSheet(task: task)
        }
        .sheet(item: $quickAdd) { request in
            QuickAddSheet(prefillDay: request.day, prefillKind: request.kind)
                .largeSheet()
        }
    }

    // MARK: - Window (which days are on screen)

    /// First on-screen day: the month's first-week start, or the rolling anchor.
    private var windowStart: Date {
        if isRollingWeeks { return weekAnchor }
        let start = calendar.startOfMonth(for: displayedMonth)
        return calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
    }

    /// Every on-screen week as 7 optional days (nil = blank month padding).
    private var weekRows: [[Date?]] {
        if isRollingWeeks {
            let start = windowStart
            return (0..<weeksShown).map { week in
                (0..<7).map { day in
                    calendar.date(byAdding: .day, value: week * 7 + day, to: start)
                }
            }
        }
        let start = calendar.startOfMonth(for: displayedMonth)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<range.count {
            days.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<($0 + 7)]) }
    }

    /// Re-anchors the grid when the given day is off screen.
    private func ensureVisible(_ day: Date) {
        if isRollingWeeks {
            let start = windowStart
            if let end = calendar.date(byAdding: .day, value: weeksShown * 7, to: start),
               day < start || day >= end {
                weekAnchor = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            }
        } else if !calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month) {
            displayedMonth = calendar.startOfMonth(for: day)
        }
        ensureWindowFetched()
    }

    /// Header-title action: select today AND re-anchor, so it works even when
    /// today is already selected but the grid was paged away (onChange alone
    /// never fires on an unchanged value).
    private func goToToday() {
        withAnimation {
            let day = calendar.startOfDay(for: today)
            selectedDay = day
            ensureVisible(day)
        }
    }

    private func ensureWindowFetched() {
        store.ensureWindowContains(windowStart)
        if let end = calendar.date(byAdding: .day, value: max(weeksShown, 6) * 7, to: windowStart) {
            store.ensureWindowContains(end)
        }
    }

    /// Chevron / swipe paging: a month, or the visible number of weeks.
    private func shift(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            if isRollingWeeks {
                if let shifted = calendar.date(byAdding: .day, value: delta * weeksShown * 7, to: weekAnchor) {
                    weekAnchor = shifted
                }
            } else if let shifted = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
                displayedMonth = calendar.startOfMonth(for: shifted)
            }
        }
        ensureWindowFetched()
    }

    // MARK: - Header

    private var headerTitle: String {
        if isRollingWeeks {
            guard let last = calendar.date(byAdding: .day, value: weeksShown * 7 - 1, to: windowStart) else {
                return Format.shortDate(windowStart)
            }
            // Cross-year windows (and windows in another year) spell the years out.
            let nowYear = calendar.component(.year, from: today)
            if calendar.component(.year, from: windowStart) == nowYear,
               calendar.component(.year, from: last) == nowYear {
                return "\(Format.shortDate(windowStart)) – \(Format.shortDate(last))"
            }
            let style = Date.FormatStyle().month(.abbreviated).day().year()
            return "\(windowStart.formatted(style)) – \(last.formatted(style))"
        }
        return displayedMonth.formatted(.dateTime.month(.wide).year())
    }

    private var gridHeader: some View {
        HStack(spacing: 8) {
            headerButton("chevron.left", label: isRollingWeeks ? "Back \(weeksShown) weeks" : "Previous month") {
                shift(-1)
            }
            Spacer(minLength: 0)
            Button {
                goToToday()
            } label: {
                Text(headerTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.wineDeep)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headerTitle). Jump to today")
            Spacer(minLength: 0)
            optionsMenu
            headerButton("chevron.right", label: isRollingWeeks ? "Forward \(weeksShown) weeks" : "Next month") {
                shift(1)
            }
        }
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.wine)
                .frame(width: 40, height: 40)
                .background(Theme.blush, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Every month-view option in one place — pickers show checkmarks, so the
    /// current setup is always visible at a glance.
    private var optionsMenu: some View {
        Menu {
            Picker("Display", selection: $displayRaw) {
                Label("Dots", systemImage: "ellipsis").tag(MonthDisplay.dots.rawValue)
                Label("Events", systemImage: "text.justify.leading").tag(MonthDisplay.events.rawValue)
            }
            Picker("Weeks Shown", selection: $weeksShown) {
                Text("Full Month").tag(0)
                ForEach([2, 4, 6, 8], id: \.self) { weeks in
                    Text("\(weeks) Weeks").tag(weeks)
                }
            }
            Section {
                Toggle("Week Numbers", isOn: $showsWeekNumbers)
                Toggle("Shade Weekends", isOn: $shadesWeekends)
                Toggle("Show Tasks", isOn: $showsTasks)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.wine)
                .frame(width: 40, height: 40)
                .background(Theme.blush, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Month view options")
    }

    // MARK: - Weekday header

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            if showsWeekNumbers {
                Color.clear.frame(width: 24, height: 1)
            }
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    private var cellHeight: CGFloat {
        guard display == .events else { return 46 }
        switch weeksShown {
        case 2: return 124
        case 4: return 100
        case 8: return 70
        default: return 80
        }
    }

    /// Event/task lines per cell in Events display, by available cell height.
    private var maxCellLines: Int {
        switch weeksShown {
        case 2: return 6
        case 4: return 4
        case 8: return 2
        default: return 3
        }
    }

    private var grid: some View {
        let rows = weekRows
        let buckets = makeBuckets(for: rows)
        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 4) {
                    if showsWeekNumbers {
                        Text(weekNumberText(for: row))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                            .padding(.top, display == .events ? 8 : 14)
                    }
                    ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day, items: buckets[day] ?? DayItems())
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: cellHeight)
                        }
                    }
                }
            }
        }
        .gesture(pageSwipe)
    }

    /// One pass over the store's windowed arrays builds every visible day's
    /// items — multi-day events land on each day they overlap, mirroring
    /// `CalendarStore.events(on:)` (all-day first, then by start).
    private func makeBuckets(for rows: [[Date?]]) -> [Date: DayItems] {
        let days = rows.flatMap { $0 }.compactMap { $0 }
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [:] }
        let start = calendar.startOfDay(for: first)

        var buckets: [Date: DayItems] = [:]
        for event in store.events where event.start < end && event.end > start {
            var day = calendar.startOfDay(for: max(event.start, start))
            while day < event.end && day < end {
                buckets[day, default: DayItems()].events.append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for task in store.tasks {
            guard let due = task.due, due >= start, due < end else { continue }
            if store.hideCompleted && task.isCompleted { continue }
            buckets[calendar.startOfDay(for: due), default: DayItems()].tasks.append(task)
        }
        for key in buckets.keys {
            buckets[key]?.events.sort { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
        }
        return buckets
    }

    private func weekNumberText(for row: [Date?]) -> String {
        guard let day = row.compactMap({ $0 }).first else { return "" }
        return "\(calendar.component(.weekOfYear, from: day))"
    }

    /// Horizontal swipe pages the grid like the chevrons — vertical drags
    /// still belong to the surrounding ScrollView.
    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > 50,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                shift(value.translation.width < 0 ? 1 : -1)
            }
    }

    @ViewBuilder
    private func dayCell(_ day: Date, items: DayItems) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isWeekend = calendar.isDateInWeekend(day)
        let openTasks = showsTasks ? items.tasks.filter { !$0.isCompleted } : []
        Group {
            switch display {
            case .dots:
                MonthDayCell(
                    day: day,
                    dots: dotColors(events: items.events, openTasks: openTasks),
                    hasOnlyTasks: items.events.isEmpty && !openTasks.isEmpty,
                    isToday: isToday,
                    isSelected: isSelected,
                    isWeekend: isWeekend
                )
            case .events:
                MonthEventCell(
                    day: day,
                    lines: cellLines(events: items.events, openTasks: openTasks),
                    maxLines: maxCellLines,
                    height: cellHeight,
                    showsMonthName: isRollingWeeks && calendar.component(.day, from: day) == 1,
                    isToday: isToday,
                    isSelected: isSelected,
                    isWeekend: isWeekend,
                    onOpenEvent: { event in
                        withAnimation { selectedDay = day }
                        selectedEvent = event
                    },
                    onOpenTask: { task in
                        withAnimation { selectedDay = day }
                        selectedTask = task
                    }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(shadesWeekends && isWeekend ? Theme.blush.opacity(0.6) : Color.clear)
        )
        .onTapGesture {
            withAnimation { selectedDay = day }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(for: day, events: items.events, openTasks: openTasks))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .contextMenu {
            Button {
                quickAdd = QuickAddRequest(day: day, kind: .event)
            } label: {
                Label("New Event Here", systemImage: "calendar.badge.plus")
            }
            Button {
                quickAdd = QuickAddRequest(day: day, kind: .task)
            } label: {
                Label("New Task Here", systemImage: "checkmark.circle")
            }
            if let openWeek {
                Button {
                    openWeek(day)
                } label: {
                    Label("Open in Week View", systemImage: "calendar.day.timeline.left")
                }
            }
        }
    }

    /// Up to three filled dots: event calendar colors first, then task list
    /// colors — the same priority as `CalendarStore.dayDots`.
    private func dotColors(events: [EventItem], openTasks: [TaskItem]) -> [Color] {
        var colors: [Color] = []
        for event in events {
            colors.append(store.color(for: event.calendarID))
            if colors.count == 3 { return colors }
        }
        for task in openTasks {
            colors.append(store.color(for: task.listID))
            if colors.count == 3 { return colors }
        }
        return colors
    }

    /// Everything a day cell can print, in display order: all-day bars first,
    /// then timed events, then open tasks.
    private func cellLines(events: [EventItem], openTasks: [TaskItem]) -> [MonthCellLine] {
        var lines: [MonthCellLine] = events.map { event in
            .event(event, store.color(for: event.calendarID))
        }
        lines += openTasks.map { task in .task(task, store.color(for: task.listID)) }
        return lines
    }

    private func accessibilitySummary(for day: Date, events: [EventItem], openTasks: [TaskItem]) -> String {
        var parts = [day.formatted(.dateTime.weekday(.wide).month(.wide).day())]
        if !events.isEmpty { parts.append("\(events.count) \(events.count == 1 ? "event" : "events")") }
        if !openTasks.isEmpty { parts.append("\(openTasks.count) \(openTasks.count == 1 ? "task" : "tasks")") }
        if events.isEmpty && openTasks.isEmpty { parts.append("no events") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Selected day agenda

    private var agendaSection: some View {
        let events = store.events(on: selectedDay)
        let tasks = store.tasks(on: selectedDay)
        return VStack(alignment: .leading, spacing: 10) {
            DayHeaderView(day: selectedDay, isToday: calendar.isDate(selectedDay, inSameDayAs: today))
            if events.isEmpty && tasks.isEmpty {
                EmptyStateText(text: "No events on this day — tap + to add one.")
            } else {
                ForEach(events) { event in
                    if event.isAllDay {
                        AllDayRow(event: event, color: store.color(for: event.calendarID))
                            .onTapGesture { selectedEvent = event }
                    } else {
                        EventRow(event: event, color: store.color(for: event.calendarID))
                            .onTapGesture { selectedEvent = event }
                    }
                }
                ForEach(tasks) { task in
                    TaskRow(task: task, color: store.color(for: task.listID)) {
                        store.toggleCompleted(task)
                    }
                    .onTapGesture { selectedTask = task }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cell content model

private enum MonthCellLine: Identifiable {
    case event(EventItem, Color)
    case task(TaskItem, Color)

    var id: String {
        switch self {
        case .event(let event, _): "e-\(event.id)"
        case .task(let task, _): "t-\(task.id)"
        }
    }
}

// MARK: - Dots day cell

/// One compact month-grid day: a 30pt number circle over up to three 6pt dots.
/// Today = filled wine circle; selected = white circle with a wine stroke
/// (the filled/outlined motif); weekends dimmed. Dots are filled calendar
/// colors for events, or one outlined wine circle when only open tasks are due.
private struct MonthDayCell: View {
    let day: Date
    let dots: [Color]
    let hasOnlyTasks: Bool
    let isToday: Bool
    let isSelected: Bool
    let isWeekend: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Same encoding as the DayTicker cells: selected = filled wine,
            // today (unselected) = outlined wine — one motif per screen.
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.subheadline.weight(isSelected || isToday ? .bold : .regular))
                .foregroundStyle(numberColor)
                .frame(width: 30, height: 30)
                .background(circleFill, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Theme.wine, lineWidth: isToday && !isSelected ? 1.5 : 0)
                )
            HStack(spacing: 3) {
                if hasOnlyTasks {
                    Circle()
                        .strokeBorder(Theme.wine, lineWidth: 1.5)
                        .frame(width: 6, height: 6)
                } else {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .contentShape(Rectangle())
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Theme.wine }
        if isWeekend { return .secondary }
        return .primary
    }

    private var circleFill: Color {
        if isSelected { return Theme.wine }
        if isToday { return .white }
        return .clear
    }
}

// MARK: - Events day cell

/// One Fantastical-style day: number badge on top, then event titles — all-day
/// events as filled mini-bars in their calendar color, timed events as
/// dot + title lines, open tasks as outlined-dot lines — capped with "+N more"
/// counted inside the line budget so cells never overflow their frame.
/// Tapping a line opens that item; tapping anywhere else selects the day.
private struct MonthEventCell: View {
    let day: Date
    let lines: [MonthCellLine]
    let maxLines: Int
    let height: CGFloat
    let showsMonthName: Bool
    let isToday: Bool
    let isSelected: Bool
    let isWeekend: Bool
    let onOpenEvent: (EventItem) -> Void
    let onOpenTask: (TaskItem) -> Void

    /// When there's overflow, the "+N more" line takes one slot of the budget.
    private var visibleCount: Int {
        lines.count > maxLines ? max(maxLines - 1, 1) : lines.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.caption.weight(isSelected || isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Theme.wine : Color.clear, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.wine, lineWidth: isToday && !isSelected ? 1.5 : 0)
                    )
                if showsMonthName {
                    Text(day.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.wineDeep)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ForEach(lines.prefix(visibleCount)) { line in
                lineView(line)
            }
            if lines.count > visibleCount {
                Text("+\(lines.count - visibleCount) more")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Theme.blush : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func lineView(_ line: MonthCellLine) -> some View {
        switch line {
        case .event(let event, let color):
            if event.isAllDay {
                Text(event.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color, in: RoundedRectangle(cornerRadius: 3))
                    .onTapGesture { onOpenEvent(event) }
            } else {
                HStack(spacing: 2) {
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                    Text(event.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 13)
                .contentShape(Rectangle())
                .onTapGesture { onOpenEvent(event) }
            }
        case .task(let task, let color):
            HStack(spacing: 2) {
                Circle()
                    .strokeBorder(color, lineWidth: 1)
                    .frame(width: 5, height: 5)
                Text(task.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 13)
            .contentShape(Rectangle())
            .onTapGesture { onOpenTask(task) }
        }
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Theme.wine }
        if isWeekend { return .secondary }
        return .primary
    }
}

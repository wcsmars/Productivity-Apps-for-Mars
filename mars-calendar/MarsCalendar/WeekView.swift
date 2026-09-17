import SwiftUI

/// Fantastical-style week mode: chevron-paged 7-column timeline with an all-day
/// lane, a 24-hour grid, and positioned event blocks in their calendar colors.
/// Like MonthGridView, this view IS the content below the ticker —
/// CalendarTabView drops it in and shares the selected day binding.
struct WeekView: View {
    @Binding var selectedDay: Date

    @EnvironmentObject private var store: CalendarStore
    @State private var displayedWeekStart: Date
    @State private var today = Date.now
    @State private var selectedEvent: EventItem?

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 48
    private let gutterWidth: CGFloat = 44
    private let trailingInset: CGFloat = 6

    init(selectedDay: Binding<Date>) {
        _selectedDay = selectedDay
        _displayedWeekStart = State(initialValue: Self.weekStart(for: selectedDay.wrappedValue, calendar: .current))
    }

    var body: some View {
        VStack(spacing: 0) {
            weekHeader
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
            GeometryReader { geo in
                let columnWidth = max(1, (geo.size.width - gutterWidth - trailingInset) / 7)
                let allDay = allDayEvents
                VStack(spacing: 0) {
                    dayHeaderRow(columnWidth: columnWidth)
                        .padding(.bottom, 6)
                    if !allDay.isEmpty {
                        allDayLane(allDay, columnWidth: columnWidth)
                    }
                    Divider()
                    timeline(columnWidth: columnWidth)
                }
            }
        }
        .background(Color.white)
        .onDayChange { today = .now }
        .onChange(of: selectedDay) { _, newDay in
            let weekStart = Self.weekStart(for: newDay, calendar: calendar)
            if weekStart != displayedWeekStart {
                displayedWeekStart = weekStart
                store.ensureWindowContains(weekStart)
            }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailSheet(event: event)
        }
    }

    // MARK: - Week math

    /// Midnight of the locale's first weekday for the week containing `date`.
    private static func weekStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: displayedWeekStart) }
    }

    private func shiftWeek(_ delta: Int) {
        guard let shifted = calendar.date(byAdding: .weekOfYear, value: delta, to: displayedWeekStart) else { return }
        displayedWeekStart = Self.weekStart(for: shifted, calendar: calendar)
        store.ensureWindowContains(displayedWeekStart)
        if let weekEnd = calendar.date(byAdding: .day, value: 6, to: displayedWeekStart) {
            store.ensureWindowContains(weekEnd)
        }
    }

    // MARK: - Header

    private var weekTitle: String {
        guard let weekEnd = calendar.date(byAdding: .day, value: 6, to: displayedWeekStart) else {
            return Format.shortDate(displayedWeekStart)
        }
        if calendar.isDate(displayedWeekStart, equalTo: weekEnd, toGranularity: .month) {
            return "\(Format.shortDate(displayedWeekStart)) – \(weekEnd.formatted(.dateTime.day()))"
        }
        return "\(Format.shortDate(displayedWeekStart)) – \(Format.shortDate(weekEnd))"
    }

    private var weekHeader: some View {
        HStack {
            Button {
                shiftWeek(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 40, height: 40)
                    .background(Theme.blush, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous week")
            Spacer()
            Text(weekTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            Spacer()
            Button {
                shiftWeek(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 40, height: 40)
                    .background(Theme.blush, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next week")
        }
    }

    // MARK: - Day column headers

    private func dayHeaderRow(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(weekDays, id: \.self) { day in
                WeekDayHeaderCell(
                    day: day,
                    isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                    isToday: calendar.isDate(day, inSameDayAs: today),
                    isWeekend: calendar.isDateInWeekend(day)
                ) {
                    withAnimation { selectedDay = day }
                }
                .frame(width: columnWidth)
            }
        }
    }

    // MARK: - All-day lane

    /// All-day events overlapping the displayed week, deduped across their days.
    private var allDayEvents: [EventItem] {
        var seen: Set<String> = []
        var result: [EventItem] = []
        for day in weekDays {
            for event in store.events(on: day) where event.isAllDay {
                if seen.insert(event.id).inserted { result.append(event) }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// The week-relative column range an all-day event covers (all-day ends are
    /// exclusive midnights, so the last covered day is end - 1 day).
    private func columnSpan(for event: EventItem) -> (start: Int, count: Int) {
        let startIndex = calendar.dateComponents(
            [.day], from: displayedWeekStart, to: calendar.startOfDay(for: event.start)
        ).day ?? 0
        let lastDay = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.end
        let endIndex = calendar.dateComponents(
            [.day], from: displayedWeekStart, to: calendar.startOfDay(for: lastDay)
        ).day ?? 0
        let first = max(0, min(6, startIndex))
        let last = max(first, min(6, endIndex))
        return (first, last - first + 1)
    }

    private func allDayLane(_ events: [EventItem], columnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                let span = columnSpan(for: event)
                Button {
                    selectedEvent = event
                } label: {
                    Text(event.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(
                            width: max(columnWidth * CGFloat(span.count) - 4, 24),
                            height: 20,
                            alignment: .leading
                        )
                        .background(store.color(for: event.calendarID), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .offset(x: gutterWidth + CGFloat(span.start) * columnWidth + 2)
                .accessibilityLabel("\(event.title), all day")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    // MARK: - Timeline

    private func timeline(columnWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    HStack(spacing: 0) {
                        Color.clear.frame(width: gutterWidth)
                        ForEach(weekDays, id: \.self) { day in
                            dayColumn(day, width: columnWidth)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 72) // keep the floating + clear of the last hours
            }
            .onAppear { proxy.scrollTo(7, anchor: .top) }
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: gutterWidth - 8, alignment: .trailing)
                        .offset(y: -6)
                    if hour > 0 {
                        Rectangle()
                            .fill(Theme.emptyCell)
                            .frame(height: 1)
                    }
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0,
              let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: displayedWeekStart)
        else { return "" }
        return date.formatted(.dateTime.hour())
    }

    // MARK: - Day columns

    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(layoutBlocks(for: day, width: width)) { block in
                eventBlock(block)
                    .offset(x: block.x, y: block.y)
            }
            if calendar.isDate(day, inSameDayAs: today) {
                nowLine(width: width)
            }
        }
        .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.emptyCell)
                .frame(width: 1)
        }
    }

    /// Current-time marker on today's column, in the suite's rose accent.
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            let dayStart = calendar.startOfDay(for: context.date)
            let y = CGFloat(context.date.timeIntervalSince(dayStart) / 3600) * hourHeight
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.rose)
                    .frame(height: 1.5)
                Circle()
                    .fill(Theme.rose)
                    .frame(width: 7, height: 7)
                    .offset(x: -3)
            }
            .frame(width: width, height: 7)
            .offset(y: y - 3.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Block layout

    private struct TimedBlock: Identifiable {
        let event: EventItem
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        var id: String { event.id }
    }

    /// Positions one day's timed events: minutes -> y/height, then overlap
    /// clusters split the column width side by side (greedy sub-columns).
    private func layoutBlocks(for day: Date, width: CGFloat) -> [TimedBlock] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        struct Placed {
            let event: EventItem
            let startY: CGFloat
            let endY: CGFloat
            var column = 0
            var columnCount = 1
        }
        var placed: [Placed] = store.events(on: day)
            .filter { !$0.isAllDay }
            .map { event in
                let start = max(event.start, dayStart)
                let end = min(event.end, dayEnd)
                let startY = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
                let endY = CGFloat(end.timeIntervalSince(dayStart) / 3600) * hourHeight
                return Placed(event: event, startY: startY, endY: max(endY, startY + 14))
            }
            .sorted { $0.startY == $1.startY ? $0.endY > $1.endY : $0.startY < $1.startY }
        guard !placed.isEmpty else { return [] }

        // Cluster = maximal run of mutually overlapping events; within one,
        // greedily assign each event to the first sub-column that has ended.
        func closeCluster(_ range: Range<Int>) {
            var columnEnds: [CGFloat] = []
            for index in range {
                if let free = columnEnds.firstIndex(where: { $0 <= placed[index].startY + 0.01 }) {
                    placed[index].column = free
                    columnEnds[free] = placed[index].endY
                } else {
                    placed[index].column = columnEnds.count
                    columnEnds.append(placed[index].endY)
                }
            }
            for index in range { placed[index].columnCount = max(1, columnEnds.count) }
        }
        var clusterStart = 0
        var clusterMaxEnd = placed[0].endY
        for index in 1..<placed.count {
            if placed[index].startY >= clusterMaxEnd - 0.01 {
                closeCluster(clusterStart..<index)
                clusterStart = index
                clusterMaxEnd = placed[index].endY
            } else {
                clusterMaxEnd = max(clusterMaxEnd, placed[index].endY)
            }
        }
        closeCluster(clusterStart..<placed.count)

        return placed.map { item in
            let subWidth = (width - 3) / CGFloat(item.columnCount)
            return TimedBlock(
                event: item.event,
                x: 2 + CGFloat(item.column) * subWidth,
                y: item.startY,
                width: max(subWidth - 2, 10),
                height: item.endY - item.startY
            )
        }
    }

    private func eventBlock(_ block: TimedBlock) -> some View {
        Button {
            selectedEvent = block.event
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(store.color(for: block.event.calendarID).opacity(0.85))
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.event.title)
                        .font(block.height < 22 ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                        .lineLimit(block.height >= 60 ? 2 : 1)
                    if block.height >= 34 {
                        Text(Format.time(block.event.start))
                            .font(.caption2)
                            .opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
            }
            .frame(width: block.width, height: block.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(block.event.title), \(Format.timeRange(block.event.start, block.event.end))"
        )
    }
}

// MARK: - Day header cell

/// Weekday letter over the day number — same selected/today motif as the
/// DayTicker: selected = filled wine circle, today (unselected) = outlined.
private struct WeekDayHeaderCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isWeekend: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(weekdaySymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isWeekend ? 0.5 : 1)
                ZStack {
                    if isSelected {
                        Circle().fill(Theme.wine)
                    } else if isToday {
                        Circle().fill(Color.white)
                        Circle().strokeBorder(Theme.wine, lineWidth: 1.5)
                    }
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 15, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                }
                .frame(width: 30, height: 30)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private var weekdaySymbol: String {
        let calendar = Calendar.current
        return calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Theme.wine }
        return isWeekend ? .secondary : .primary
    }
}

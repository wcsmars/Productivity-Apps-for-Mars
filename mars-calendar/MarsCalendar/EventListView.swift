import SwiftUI

/// Combined, day-grouped event + task list with pinned day headers and two-way
/// scroll sync with the DayTicker: scrolling the list drives `selectedDay`, and
/// outside selection changes (ticker taps, Today button) scroll the list.
struct EventListView: View {
    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var weather: WeatherService
    @Binding var selectedDay: Date

    @State private var topVisibleDay: Date?
    @State private var isProgrammaticScroll = false
    @State private var scrollTarget: Date?
    @State private var scrollGeneration = 0
    @State private var selectedEvent: EventItem?
    @State private var selectedTask: TaskItem?

    private let calendar = Calendar.current

    init(selectedDay: Binding<Date>) {
        _selectedDay = selectedDay
        // Seed the scroll position so the list opens on the selected day.
        _topVisibleDay = State(initialValue: Calendar.current.startOfDay(for: selectedDay.wrappedValue))
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailSheet(event: event)
                .mediumOrLargeSheet()
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailSheet(task: task)
                .mediumOrLargeSheet()
        }
    }

    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(listDays, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            DayHeaderView(day: day, isToday: calendar.isDateInToday(day))
                            if let forecast = weather.weather(on: day) {
                                WeatherBadge(weather: forecast)
                                    .padding(.top, 6)
                            }
                        }
                        dayContent(for: day)
                    }
                }
            }
            .scrollTargetLayout()
            .padding()
            .padding(.bottom, 72)
        }
        .background(Color.white)
        .scrollPosition(id: $topVisibleDay, anchor: .top)
        .onAppear {
            // The seeded scrollPosition can land short once lazy content above
            // the anchor realizes; re-assert deterministically after first layout.
            DispatchQueue.main.async {
                scrollProgrammatically(to: calendar.startOfDay(for: selectedDay), with: proxy, animated: false)
            }
        }
        .onChange(of: topVisibleDay) { _, newValue in
            guard let newValue else { return }
            if isProgrammaticScroll {
                // Swallow intermediate positions of an in-flight programmatic
                // scroll; release the guard the moment the target is reached.
                if let target = scrollTarget, calendar.isDate(newValue, inSameDayAs: target) {
                    isProgrammaticScroll = false
                    scrollTarget = nil
                }
                return
            }
            if !calendar.isDate(newValue, inSameDayAs: selectedDay) {
                selectedDay = newValue
            }
        }
        .onChange(of: selectedDay) { _, newValue in
            let day = calendar.startOfDay(for: newValue)
            if let top = topVisibleDay, calendar.isDate(top, inSameDayAs: day) { return }
            scrollProgrammatically(to: day, with: proxy, animated: true)
        }
    }

    // MARK: - Days

    /// Days shown: every day with items in a window around today/selection,
    /// plus today and the selected day even when empty.
    private var listDays: [Date] {
        let today = calendar.startOfDay(for: .now)
        let selected = calendar.startOfDay(for: selectedDay)
        var start = min(
            calendar.date(byAdding: .day, value: -60, to: today) ?? today,
            calendar.date(byAdding: .day, value: -30, to: selected) ?? selected
        )
        var end = max(
            calendar.date(byAdding: .day, value: 120, to: today) ?? today,
            calendar.date(byAdding: .day, value: 60, to: selected) ?? selected
        )
        start = max(start, calendar.startOfDay(for: store.windowStart))
        end = min(end, calendar.startOfDay(for: store.windowEnd))
        var days = store.days(withItemsFrom: start, to: end)
        days.insert(today)
        days.insert(selected)
        return days.sorted()
    }

    // MARK: - Day content

    @ViewBuilder
    private func dayContent(for day: Date) -> some View {
        let entries = entries(for: day)
        if entries.isEmpty {
            Text("No events — tap + to add one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
        }
    }

    /// Overdue tasks (today only) first, then all-day bars, then date-only
    /// tasks, then timed events and timed tasks interleaved by time.
    private func entries(for day: Date) -> [ListEntry] {
        var result: [ListEntry] = []
        if calendar.isDateInToday(day) {
            result += store.overdueTasks.map { ListEntry.task($0, showsDate: true) }
        }
        let events = store.events(on: day)
        let tasks = store.tasks(on: day)
        result += events.filter(\.isAllDay).map { ListEntry.allDay($0) }
        result += tasks.filter { !$0.hasDueTime }.map { ListEntry.task($0, showsDate: false) }
        var timed: [(Date, ListEntry)] = events
            .filter { !$0.isAllDay }
            .map { ($0.start, ListEntry.event($0)) }
        timed += tasks.filter(\.hasDueTime).compactMap { task in
            task.due.map { ($0, ListEntry.task(task, showsDate: false)) }
        }
        result += timed.sorted { $0.0 < $1.0 }.map(\.1)
        return result
    }

    @ViewBuilder
    private func row(for entry: ListEntry) -> some View {
        switch entry {
        case .allDay(let event):
            Button {
                selectedEvent = event
            } label: {
                AllDayRow(event: event, color: store.color(for: event.calendarID))
            }
            .buttonStyle(.plain)
        case .event(let event):
            Button {
                selectedEvent = event
            } label: {
                EventRow(event: event, color: store.color(for: event.calendarID))
            }
            .buttonStyle(.plain)
        case .task(let task, let showsDate):
            TaskRow(task: task, color: store.color(for: task.listID), showsDate: showsDate) {
                store.toggleCompleted(task)
            }
            .onTapGesture { selectedTask = task }
        }
    }

    // MARK: - Scroll sync

    /// Scrolls the list to a day while suppressing the `topVisibleDay` →
    /// `selectedDay` echo until the target lands (with a generation-checked
    /// timer as a fallback, so rapid re-targets can't release each other's guard).
    private func scrollProgrammatically(to day: Date, with proxy: ScrollViewProxy, animated: Bool) {
        isProgrammaticScroll = true
        scrollTarget = day
        scrollGeneration += 1
        let generation = scrollGeneration
        if animated {
            withAnimation { proxy.scrollTo(day, anchor: .top) }
        } else {
            proxy.scrollTo(day, anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard generation == scrollGeneration else { return }
            isProgrammaticScroll = false
            scrollTarget = nil
        }
    }
}

// MARK: - Entries

private enum ListEntry: Identifiable {
    case allDay(EventItem)
    case event(EventItem)
    case task(TaskItem, showsDate: Bool)

    var id: String {
        switch self {
        case .allDay(let event): "allday-\(event.id)"
        case .event(let event): "event-\(event.id)"
        case .task(let task, _): "task-\(task.id)"
        }
    }
}

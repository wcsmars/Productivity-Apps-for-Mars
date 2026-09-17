import SwiftUI

/// Whole-calendar search: live filtering across events and tasks, past and
/// future, rendered as the familiar day-grouped list plus a tasks section.
struct SearchTabView: View {
    @EnvironmentObject private var store: CalendarStore
    @State private var query = ""
    @State private var selectedEvent: EventItem?
    @State private var selectedTask: TaskItem?

    private let calendar = Calendar.current
    private let maxEventResults = 100

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchField
                    results
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Search")
            .sheet(item: $selectedEvent) { event in
                EventDetailSheet(event: event)
                    .mediumOrLargeSheet()
            }
            .sheet(item: $selectedTask) { task in
                TaskDetailSheet(task: task)
                    .mediumOrLargeSheet()
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.wine)
            TextField("Search events and tasks", text: $query)
                .font(.subheadline.weight(.semibold))
                .autocorrectionDisabled()
                .padding(.vertical, 12)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            EmptyStateText(text: "Search your whole calendar — past and future, events and tasks.")
        } else {
            let matches = store.searchItems(matching: query)
            if matches.events.isEmpty && matches.tasks.isEmpty {
                EmptyStateText(text: "No matches for “\(trimmed)”.")
            } else {
                // Rank by proximity to now — today and upcoming first (ascending),
                // then the past (most recent first) — so the cap can never bury
                // current occurrences of recurring events under year-old ones.
                let todayStart = calendar.startOfDay(for: .now)
                let upcoming = matches.events.filter { $0.end >= todayStart }.sorted { $0.start < $1.start }
                let past = matches.events.filter { $0.end < todayStart }.sorted { $0.start > $1.start }
                let ranked = upcoming + past
                let clipped = ranked.count > maxEventResults

                ForEach(dayGroups(from: Array(ranked.prefix(maxEventResults)))) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        DayHeaderView(day: group.day, isToday: calendar.isDateInToday(group.day))
                        ForEach(group.events) { event in
                            eventRow(event)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if clipped {
                    Text("Showing first 100 matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !matches.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Tasks")
                        ForEach(matches.tasks) { task in
                            taskRow(task)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func eventRow(_ event: EventItem) -> some View {
        Button {
            selectedEvent = event
        } label: {
            if event.isAllDay {
                AllDayRow(event: event, color: store.color(for: event.calendarID))
            } else {
                EventRow(event: event, color: store.color(for: event.calendarID))
            }
        }
        .buttonStyle(.plain)
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            selectedTask = task
        } label: {
            TaskRow(task: task, color: store.color(for: task.listID), showsDate: true) {
                store.toggleCompleted(task)
            }
        }
        .buttonStyle(.plain)
    }

    private func dayGroups(from events: [EventItem]) -> [DayGroup] {
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            DayGroup(day: day, events: grouped[day]!.sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            })
        }
    }
}

// MARK: - File-local helpers

private struct DayGroup: Identifiable {
    let day: Date
    let events: [EventItem]
    var id: Date { day }
}

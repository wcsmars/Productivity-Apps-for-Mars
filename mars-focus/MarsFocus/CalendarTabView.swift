import SwiftUI

private struct DaySelection: Identifiable {
    let day: Date
    var id: Date { day }
}

/// Month calendar where planned block windows (one-off + recurring) show up
/// automatically, plus the schedule management sections.
struct CalendarTabView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore

    @State private var displayedMonth = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: DaySelection?
    @State private var editingRule: ScheduleRule?
    @State private var creatingRule = false
    @State private var today = Date.now

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monthHeader
                    weekdayHeader
                    monthGrid
                    legend
                    if !sessionStore.scheduled.isEmpty {
                        upcomingSection
                    }
                    recurringSection
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creatingRule = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("New schedule")
                }
            }
            .sheet(item: $selectedDay) { selection in
                DayDetailSheet(day: selection.day)
            }
            .sheet(item: $editingRule) { rule in
                RuleEditorSheet(existing: rule)
            }
            .sheet(isPresented: $creatingRule) {
                RuleEditorSheet(existing: nil)
            }
            .onDayChange { today = .now }
        }
    }

    // MARK: - Month grid

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 40, height: 40)
                    .background(Theme.blush, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            Spacer()
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 40, height: 40)
                    .background(Theme.blush, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthDays: [Date?] {
        let start = calendar.startOfMonth(for: displayedMonth)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<range.count {
            days.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        return days
    }

    private var monthGrid: some View {
        let levels = sessionStore.dayLevels()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    let dayStart = calendar.startOfDay(for: day)
                    CalendarDayCell(
                        day: day,
                        hasFocus: (levels[dayStart] ?? 0) > 0,
                        hasSlot: sessionStore.hasPlannedSlot(on: day),
                        isToday: calendar.isDate(day, inSameDayAs: today)
                    )
                    .onTapGesture {
                        selectedDay = DaySelection(day: dayStart)
                    }
                } else {
                    Color.clear.frame(height: 46)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Circle().fill(Theme.wine).frame(width: 6, height: 6)
                Text("Focused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().strokeBorder(Theme.wine, lineWidth: 1.5).frame(width: 6, height: 6)
                Text("Planned block")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func shiftMonth(_ delta: Int) {
        if let shifted = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = calendar.startOfMonth(for: shifted)
        }
    }

    // MARK: - Schedule sections

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            ForEach(sessionStore.scheduled) { session in
                UpcomingRow(
                    session: session,
                    listNames: blocklistStore.blocklists(withIDs: session.blocklistIDs).map(\.name),
                    onCancel: { sessionStore.cancelScheduled(session) }
                )
            }
        }
    }

    private var recurringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recurring")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            if sessionStore.rules.isEmpty {
                Text("No recurring schedules yet — tap + to block distractions at the same time every day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(sessionStore.rules) { rule in
                    ruleCard(rule)
                }
            }
        }
    }

    private func ruleCard(_ rule: ScheduleRule) -> some View {
        HStack(spacing: 12) {
            Button {
                editingRule = rule
            } label: {
                HStack(spacing: 12) {
                    // Filled-vs-outlined is the app's on/off motif.
                    Image(systemName: "repeat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(rule.isEnabled ? .white : Theme.wine)
                        .frame(width: 34, height: 34)
                        .background(rule.isEnabled ? Theme.wine : Color.white, in: Circle())
                        .overlay(
                            Circle().strokeBorder(Theme.wine, lineWidth: rule.isEnabled ? 0 : 1.5)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(rule.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(rule.isEnabled ? Color.primary : Color.secondary)
                            if rule.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.wine)
                            }
                        }
                        Text("\(rule.daysSummary(calendar: calendar)) · \(rule.timeSummary(calendar: calendar))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(listSummary(for: rule))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { sessionStore.setRule(rule, enabled: $0) }
            ))
            .labelsHidden()
            .tint(Theme.wine)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private func listSummary(for rule: ScheduleRule) -> String {
        let names = blocklistStore.blocklists(withIDs: rule.blocklistIDs).map(\.name)
        return names.isEmpty ? "No blocklists" : names.joined(separator: ", ")
    }
}

// MARK: - Day cell

private struct CalendarDayCell: View {
    let day: Date
    let hasFocus: Bool
    let hasSlot: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.subheadline.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? .white : .primary)
                .frame(width: 30, height: 30)
                .background(isToday ? Theme.wine : .clear, in: Circle())
            HStack(spacing: 3) {
                // Solid wine, matching the legend — intensity lives in the
                // History heatmap, the calendar dot is binary.
                if hasFocus {
                    Circle()
                        .fill(Theme.wine)
                        .frame(width: 6, height: 6)
                }
                if hasSlot {
                    Circle()
                        .strokeBorder(Theme.wine, lineWidth: 1.5)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .contentShape(Rectangle())
    }
}

// MARK: - Day detail

private struct DayDetailSheet: View {
    let day: Date

    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var planningSession = false

    private let calendar = Calendar.current

    private var isPast: Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: .now)
    }

    /// A sensible default start for a new block on this day: the next full
    /// hour today (clamped so it never rolls onto tomorrow after 11 PM), or
    /// 9:00 AM on a future day.
    private var defaultStart: Date {
        let dayStart = calendar.startOfDay(for: day)
        if calendar.isDateInToday(day) {
            let next = Date.now.addingTimeInterval(3600)
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: next)
            let candidate = calendar.date(from: components) ?? next
            if calendar.isDate(candidate, inSameDayAs: day) { return candidate }
            return calendar.time(atMinutes: 23 * 60, on: dayStart) ?? candidate
        }
        return calendar.time(atMinutes: 9 * 60, on: dayStart) ?? dayStart
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Past days have no meaningful "planned" state — what
                    // actually happened is in the sessions list below.
                    if !isPast {
                        slotsSection
                    }
                    sessionsSection
                    if !isPast {
                        planButton
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $planningSession) {
                StartSessionSheet(presetStartAt: defaultStart)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked Time")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            let slots = sessionStore.plannedSlots(on: day)
            if slots.isEmpty {
                Text("No blocks planned yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Theme.wine, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slot.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(slot.start.formatted(date: .omitted, time: .shortened)) – \(slot.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var runningSession: ActiveSession? {
        guard calendar.isDateInToday(day) else { return nil }
        return sessionStore.active
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Focus Sessions")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            if let session = runningSession {
                // The month grid's dot already counts the running session, so
                // the sheet must show it too.
                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.wine, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.scheduleName ?? "Focus session")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("In progress · ends \(session.endsAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.duration(max(0, min(Date.now, session.endsAt).timeIntervalSince(session.startedAt))))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.wine)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            }
            let records = sessionStore.sessions(on: day)
            if records.isEmpty && runningSession == nil {
                Text("Nothing logged on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.endedEarly ? "shield.slash" : "checkmark.shield.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(record.endedEarly ? Theme.wine : .white)
                            .frame(width: 34, height: 34)
                            .background(record.endedEarly ? Color.white : Theme.wine, in: Circle())
                            .overlay(
                                Circle().strokeBorder(Theme.wine, lineWidth: record.endedEarly ? 1.5 : 0)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.duration(record.duration))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.wine)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var planButton: some View {
        Button {
            planningSession = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Block Time on This Day")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

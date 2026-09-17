import SwiftUI

struct DaySelection: Identifiable {
    let day: Date
    var id: Date { day }
}

struct CalendarTabView: View {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case dots = "Dots"
        case numbers = "Numbers"
        case heat = "Heat"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: EntryStore
    @State private var displayedMonth = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: DaySelection?
    @State private var mode: DisplayMode
    @State private var filter: TrackerCategory?
    @State private var today = Date.now

    private let calendar = Calendar.current

    init() {
        var initial = DisplayMode.dots
        var initialFilter: TrackerCategory?
        #if DEBUG
        // Launch-argument overrides so UI verification can screenshot each mode.
        if CommandLine.arguments.contains("-calendarNumbers") { initial = .numbers; initialFilter = .study }
        if CommandLine.arguments.contains("-calendarHeat") { initial = .heat; initialFilter = .study }
        #endif
        _mode = State(initialValue: initial)
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modePicker
                    if mode != .dots {
                        CategoryFilterChips(filter: $filter)
                    }
                    monthHeader
                    weekdayHeader
                    monthGrid
                    legend
                }
                .padding()
                .contentColumn()
            }
            .background(Color.white)
            .navigationTitle("Calendar")
            .sheet(item: $selectedDay) { selection in
                DayDetailSheet(day: selection.day)
            }
            .onDayChange { today = .now }
        }
    }

    private var modePicker: some View {
        Picker("Display", selection: $mode) {
            ForEach(DisplayMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 40, height: 40)
                    .background(Theme.blush, in: Circle())
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
        let levels = mode == .heat ? store.dayLevels(filter: filter) : [:]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    let isCurrentDay = calendar.isDate(day, inSameDayAs: today)
                    let isFuture = day > today && !isCurrentDay
                    DayCell(
                        day: day,
                        mode: mode,
                        categories: mode == .dots ? store.categoriesLogged(on: day) : [],
                        value: mode == .numbers && !isFuture ? store.calendarValue(on: day, filter: filter) : nil,
                        level: levels[calendar.startOfDay(for: day)] ?? 0,
                        isToday: isCurrentDay,
                        isFuture: isFuture
                    )
                    .onTapGesture {
                        // Future days are styled as disabled; don't let them log.
                        guard !isFuture else { return }
                        selectedDay = DaySelection(day: day)
                    }
                } else {
                    Color.clear.frame(height: 46)
                }
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        switch mode {
        case .dots:
            HStack(spacing: 14) {
                ForEach(TrackerCategory.allCases) { category in
                    HStack(spacing: 4) {
                        CategoryDot(category: category)
                        Text(category.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        case .numbers:
            Text(numbersLegendText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        case .heat:
            HStack(spacing: 4) {
                if filter == .weight {
                    // Weigh-ins are binary — no intensity ramp to explain.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.heat(4))
                        .frame(width: 11, height: 11)
                    Text("Logged").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.heat(level))
                            .frame(width: 11, height: 11)
                    }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                    if let filter, store.goals[filter] != nil {
                        Text("· full = goal met")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var numbersLegendText: String {
        guard let filter else { return "Entries logged per day" }
        switch filter {
        case .weight: return "Last weigh-in of each day"
        default: return "Daily \(filter.title.lowercased()) total"
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let shifted = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = calendar.startOfMonth(for: shifted)
        }
    }
}

struct DayCell: View {
    let day: Date
    var mode: CalendarTabView.DisplayMode = .dots
    let categories: [TrackerCategory]
    var value: String?
    var level: Int = 0
    let isToday: Bool
    let isFuture: Bool

    private var dayNumber: String { "\(Calendar.current.component(.day, from: day))" }

    var body: some View {
        Group {
            switch mode {
            case .dots: dotsCell
            case .numbers: numbersCell
            case .heat: heatCell
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .contentShape(Rectangle())
    }

    private var dotsCell: some View {
        VStack(spacing: 4) {
            Text(dayNumber)
                .font(.subheadline.weight(isToday ? .bold : .regular))
                .foregroundStyle(isFuture ? Color.secondary.opacity(0.4) : (isToday ? .white : .primary))
                .frame(width: 30, height: 30)
                .background(isToday ? Theme.wine : .clear, in: Circle())
            HStack(spacing: 3) {
                ForEach(categories) { category in
                    CategoryDot(category: category)
                }
            }
            .frame(height: 6)
        }
    }

    private var numbersCell: some View {
        VStack(spacing: 2) {
            Text(dayNumber)
                .font(.caption2.weight(isToday ? .bold : .regular))
                .foregroundStyle(isFuture ? Color.secondary.opacity(0.4) : (isToday ? Theme.wine : .secondary))
            Text(value ?? " ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.wine)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var heatCell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isFuture ? Color.clear : Theme.heat(level))
            if isToday {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.wineDeep, lineWidth: 2)
            }
            Text(dayNumber)
                .font(.caption.weight(isToday ? .bold : .semibold))
                .foregroundStyle(
                    isFuture ? Color.secondary.opacity(0.4) : (level >= 3 ? .white : Theme.wineDeep)
                )
        }
        .frame(width: 38, height: 38)
    }
}

struct CategoryDot: View {
    let category: TrackerCategory

    var body: some View {
        if category.isOutlined {
            Circle()
                .strokeBorder(Theme.wine, lineWidth: 1.5)
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .fill(category.color)
                .frame(width: 6, height: 6)
        }
    }
}

struct DayDetailSheet: View {
    let day: Date

    @EnvironmentObject private var store: EntryStore
    @Environment(\.dismiss) private var dismiss
    @State private var addingCategory: TrackerCategory?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quickAddRow
                    entriesList
                }
                .padding()
                .contentColumn()
            }
            .background(Color.white)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $addingCategory) { category in
                AddEntrySheet(category: category, day: day)
            }
        }
        .mediumOrLargeSheet()
    }

    private var quickAddRow: some View {
        HStack(spacing: 8) {
            ForEach(TrackerCategory.allCases) { category in
                Button {
                    addingCategory = category
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: category.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(category.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(category.isOutlined ? Theme.wine : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        category.isOutlined ? Color.white : category.color,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.wine, lineWidth: category.isOutlined ? 1.5 : 0)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var entriesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            let entries = store.entries(on: day)
            if entries.isEmpty {
                Text("Nothing logged on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(entries) { entry in
                    EntryRow(entry: entry) {
                        store.delete(entry)
                    }
                }
            }
        }
    }
}

import SwiftUI

/// Fantastical-style year mode: twelve tappable mini-months with chevron year
/// paging. Tapping a month moves the selection there (today when the month
/// contains it, otherwise the 1st) and hands the month start back to
/// CalendarTabView via `onPickMonth` so it can switch into month mode.
struct YearView: View {
    @Binding var selectedDay: Date
    let onPickMonth: (Date) -> Void

    @State private var displayedYearStart: Date
    @State private var today = Date.now

    private let calendar = Calendar.current

    init(selectedDay: Binding<Date>, onPickMonth: @escaping (Date) -> Void) {
        _selectedDay = selectedDay
        self.onPickMonth = onPickMonth
        _displayedYearStart = State(initialValue: Self.yearStart(for: selectedDay.wrappedValue, calendar: .current))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                yearHeader
                monthsGrid
            }
            .padding()
            .padding(.bottom, 72) // keep the floating + clear of the last row
        }
        .background(Color.white)
        .onDayChange { today = .now }
        .onChange(of: selectedDay) { _, newDay in
            if !calendar.isDate(newDay, equalTo: displayedYearStart, toGranularity: .year) {
                displayedYearStart = Self.yearStart(for: newDay, calendar: calendar)
            }
        }
    }

    // MARK: - Year math

    private static func yearStart(for date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year], from: date)) ?? calendar.startOfDay(for: date)
    }

    private func shiftYear(_ delta: Int) {
        if let shifted = calendar.date(byAdding: .year, value: delta, to: displayedYearStart) {
            displayedYearStart = shifted
        }
    }

    // MARK: - Header

    private var yearHeader: some View {
        HStack {
            Button {
                shiftYear(-1)
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
            .accessibilityLabel("Previous year")
            Spacer()
            Text(displayedYearStart, format: .dateTime.year())
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            Spacer()
            Button {
                shiftYear(1)
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
            .accessibilityLabel("Next year")
        }
    }

    // MARK: - Months

    private var monthsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(0..<12, id: \.self) { offset in
                if let monthStart = calendar.date(byAdding: .month, value: offset, to: displayedYearStart) {
                    Button {
                        pick(monthStart)
                    } label: {
                        MiniMonth(monthStart: monthStart, today: today)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pick(_ monthStart: Date) {
        let startOfToday = calendar.startOfDay(for: today)
        selectedDay = calendar.isDate(startOfToday, equalTo: monthStart, toGranularity: .month)
            ? startOfToday
            : monthStart
        onPickMonth(monthStart)
    }
}

// MARK: - Mini month

/// One tappable month tile: bold month name (wine when it is the current
/// month) over a 7-column grid of caption day numbers, today ringed in a
/// filled wine circle. No weekday row — the tile stays a compact glance.
private struct MiniMonth: View {
    let monthStart: Date
    let today: Date

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monthStart, format: .dateTime.month(.wide))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isCurrentMonth ? Theme.wine : Theme.wineDeep)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Text(day.formatted(.dateTime.day()))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(isToday(day) ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(isToday(day) ? Theme.wine : .clear, in: Circle())
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(height: 18)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monthStart.formatted(.dateTime.month(.wide).year()))
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(monthStart, equalTo: today, toGranularity: .month)
    }

    private func isToday(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: today)
    }

    /// The month's days with nil leading blanks so the first row starts on the
    /// locale's first weekday — same shape as MonthGridView's grid.
    private var monthDays: [Date?] {
        let start = calendar.startOfMonth(for: monthStart)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<range.count {
            days.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        return days
    }
}

import SwiftUI

/// Fantastical-style horizontal date strip: one 46pt cell per day across the
/// store's fetch window, with weekday letter, day number, and up to three
/// calendar-colored dots. Selected day = filled wine circle; today = outlined.
struct DayTicker: View {
    @EnvironmentObject private var store: CalendarStore
    @Binding var selectedDay: Date
    var onTap: ((Date) -> Void)?

    private let calendar = Calendar.current

    init(selectedDay: Binding<Date>, onTap: ((Date) -> Void)? = nil) {
        _selectedDay = selectedDay
        self.onTap = onTap
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<dayCount, id: \.self) { offset in
                            if let day = day(at: offset) {
                                TickerCell(
                                    day: day,
                                    isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                                    isToday: calendar.isDateInToday(day),
                                    isWeekend: calendar.isDateInWeekend(day),
                                    dots: store.dayDots(on: day, limit: 3)
                                ) {
                                    withAnimation { selectedDay = day }
                                    onTap?(day)
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .frame(height: 70)
                .onAppear { scrollToSelected(with: proxy, animated: false) }
                .onChange(of: selectedDay) { scrollToSelected(with: proxy, animated: true) }
                // Window expansion re-maps offset ids to different days; recenter
                // so the strip doesn't silently jump by the expansion amount.
                .onChange(of: store.windowStart) { scrollToSelected(with: proxy, animated: false) }
            }
            Divider()
        }
        .background(Color.white)
    }

    // MARK: - Day math

    private var windowStart: Date { calendar.startOfDay(for: store.windowStart) }

    /// windowEnd is exclusive (its day is never fetched), so the last cell is the day before it.
    private var dayCount: Int {
        calendar.dateComponents([.day], from: windowStart, to: store.windowEnd).day ?? 0
    }

    private func day(at offset: Int) -> Date? {
        calendar.date(byAdding: .day, value: offset, to: windowStart)
    }

    /// Centers the selected day. ScrollViewReader only writes (never reads back),
    /// so ticker-driven selection can't feed back into another scroll.
    private func scrollToSelected(with proxy: ScrollViewProxy, animated: Bool) {
        guard let offset = calendar.dateComponents(
            [.day], from: windowStart, to: calendar.startOfDay(for: selectedDay)
        ).day, (0..<dayCount).contains(offset) else { return }
        if animated {
            withAnimation { proxy.scrollTo(offset, anchor: .center) }
        } else {
            proxy.scrollTo(offset, anchor: .center)
        }
    }
}

// MARK: - Cell

private struct TickerCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isWeekend: Bool
    let dots: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
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
                .frame(width: 34, height: 34)
                HStack(spacing: 3) {
                    ForEach(dots.indices, id: \.self) { index in
                        Circle()
                            .fill(dots[index])
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 46)
            .padding(.vertical, 6)
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

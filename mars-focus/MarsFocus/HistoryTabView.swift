import SwiftUI

struct HistoryTabView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var today = Date.now

    private let calendar = Calendar.current
    private let weeksToShow = 26

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statTiles
                    heatmapCard
                    recentSessions
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("History")
            .onDayChange { today = .now }
        }
    }

    // MARK: - Stats

    private var statTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(value: "\(sessionStore.currentStreak(asOf: today))", label: "Current streak", suffix: "days")
            StatTile(value: "\(sessionStore.bestStreak())", label: "Best streak", suffix: "days")
            StatTile(value: "\(sessionStore.completedSessionCount)", label: "Sessions completed")
            StatTile(value: Format.duration(sessionStore.totalFocusTime()), label: "Total focus time")
        }
    }

    // MARK: - Heatmap

    private var weeks: [[Date]] {
        // startOfDay after every byAdding step: around DST jumps that skip
        // midnight, byAdding carries the shifted wall time forward, and cell
        // dates must exactly equal the startOfDay keys used by dayLevels.
        let todayStart = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: todayStart)
        let daysIntoWeek = (weekday - calendar.firstWeekday + 7) % 7
        guard let rawWeekStart = calendar.date(byAdding: .day, value: -daysIntoWeek, to: todayStart) else { return [] }
        let currentWeekStart = calendar.startOfDay(for: rawWeekStart)
        var result: [[Date]] = []
        for weekOffset in stride(from: weeksToShow - 1, through: 0, by: -1) {
            guard let weekStart = calendar.date(byAdding: .day, value: -7 * weekOffset, to: currentWeekStart) else { continue }
            var week: [Date] = []
            for dayOffset in 0..<7 {
                if let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) {
                    week.append(calendar.startOfDay(for: day))
                }
            }
            result.append(week)
        }
        return result
    }

    private var heatmapCard: some View {
        let levels = sessionStore.dayLevels()
        let today = calendar.startOfDay(for: today)
        let allWeeks = weeks
        return VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(for: allWeeks)
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(Array(allWeeks.enumerated()), id: \.offset) { index, week in
                                VStack(spacing: 3) {
                                    ForEach(week, id: \.self) { day in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(day > today ? Color.clear : Theme.heat(levels[day] ?? 0))
                                            .frame(width: 13, height: 13)
                                    }
                                }
                                .id(index)
                            }
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(allWeeks.count - 1, anchor: .trailing)
                }
            }
            legendRow
        }
        .padding(14)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private func monthLabels(for weeks: [[Date]]) -> some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                Group {
                    if let first = week.first, shouldLabelMonth(at: index, in: weeks) {
                        Text(first, format: .dateTime.month(.abbreviated))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        Text("")
                    }
                }
                .frame(width: 13, alignment: .leading)
            }
        }
        .frame(height: 14, alignment: .top)
    }

    private func shouldLabelMonth(at index: Int, in weeks: [[Date]]) -> Bool {
        guard let current = weeks[index].first else { return false }
        // Label the very first column and every column that starts a new month,
        // but skip the first column if the next label would overlap it.
        guard index > 0 else {
            guard weeks.count > 1, let next = weeks[1].first else { return true }
            return calendar.component(.month, from: next) == calendar.component(.month, from: current)
        }
        guard let previous = weeks[index - 1].first else { return false }
        return calendar.component(.month, from: previous) != calendar.component(.month, from: current)
    }

    private var legendRow: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.heat(level))
                    .frame(width: 11, height: 11)
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Sessions")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            let recent = Array(sessionStore.history.sorted { $0.startedAt > $1.startedAt }.prefix(15))
            if recent.isEmpty {
                Text("No sessions yet — start your first focus session from the Focus tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(recent) { record in
                    SessionRow(record: record)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        HStack(spacing: 12) {
            // Completed sessions are solid wine; ended-early ones are outlined,
            // echoing the filled/outlined split used across the app.
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
                Text(record.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.duration(record.duration))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
                if record.endedEarly {
                    Text("ended early")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var suffix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.wine)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let suffix {
                    Text(suffix)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

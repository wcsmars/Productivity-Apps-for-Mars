import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: EntryStore
    @State private var addingCategory: TrackerCategory?
    @State private var showingGoals = false
    @State private var showingAccount = false
    @State private var today = Date.now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    categoryGrid
                    todaysLog
                }
                .padding()
                .contentColumn()
            }
            .background(Color.white)
            .navigationTitle("Mars Momentum")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingAccount = true
                    } label: {
                        Image(systemName: store.account == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("Account & sync")
                    Button {
                        showingGoals = true
                    } label: {
                        Image(systemName: "target")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("Edit goals")
                }
            }
            .sheet(item: $addingCategory) { category in
                AddEntrySheet(category: category, day: today)
            }
            .sheet(isPresented: $showingGoals) {
                GoalsSheet()
            }
            .sheet(isPresented: $showingAccount) {
                AccountSheet()
            }
            .onDayChange { today = .now }
        }
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(TrackerCategory.allCases) { category in
                Button {
                    addingCategory = category
                } label: {
                    CategoryCard(
                        category: category,
                        summary: store.summary(for: category, on: today),
                        progress: store.goalProgress(for: category, on: today),
                        targetWeight: category == .weight ? store.goals[.weight] : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var todaysLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today's Log")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            let entries = store.entries(on: today)
            if entries.isEmpty {
                Text("Nothing logged yet — tap a card to add your first entry.")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryCard: View {
    let category: TrackerCategory
    let summary: String?
    var progress: (achieved: Double, goal: Goal)?
    var targetWeight: Goal?

    private var goalMet: Bool {
        guard let progress else { return false }
        // Tolerance matches EntryStore's level(): IEEE sums of decimal counts
        // (0.1 + 0.7) must still satisfy a 0.8 goal.
        return progress.achieved >= progress.goal.amount - 1e-9
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: category.icon)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                if goalMet {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .opacity(0.6)
                }
            }
            Spacer(minLength: 0)
            Text(category.title)
                .font(.headline)
            subtitle
            if let progress {
                goalBar(progress)
            }
        }
        .foregroundStyle(category.isOutlined ? Theme.wine : .white)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(
            category.isOutlined ? Color.white : category.color,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.wine, lineWidth: category.isOutlined ? 1.5 : 0)
        )
    }

    @ViewBuilder
    private var subtitle: some View {
        if let progress {
            let achievedText = progress.goal.kind == .duration
                ? Format.duration(progress.achieved)
                : Format.number(progress.achieved)
            Text("\(achievedText) / \(progress.goal.formatted)")
                .font(.subheadline.weight(.semibold))
                .opacity(0.85)
        } else if category == .weight, let targetWeight {
            Text("\(summary ?? "—") → \(Format.number(targetWeight.amount, unit: category.numberUnit))")
                .font(.subheadline.weight(.semibold))
                .opacity(0.85)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(summary ?? "—")
                .font(.subheadline.weight(.semibold))
                .opacity(0.85)
        }
    }

    private func goalBar(_ progress: (achieved: Double, goal: Goal)) -> some View {
        let fraction = min(1, max(0, progress.achieved / progress.goal.amount))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

struct EntryRow: View {
    let entry: Entry
    var onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.category.isOutlined ? Theme.wine : .white)
                .frame(width: 34, height: 34)
                .background(
                    entry.category.isOutlined ? Color.white : entry.category.color,
                    in: Circle()
                )
                .overlay(
                    Circle().strokeBorder(Theme.wine, lineWidth: entry.category.isOutlined ? 1.5 : 0)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category.title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.formattedAmount)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.wine)
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(entry.category.title) entry")
            .confirmationDialog(
                "Delete this \(entry.category.title.lowercased()) entry?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

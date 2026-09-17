import SwiftUI

// MARK: - Eisenhower quadrants

/// Eisenhower matrix quadrant. Raw values are persisted as manual placements —
/// don't renumber.
enum Quadrant: Int, CaseIterable, Identifiable {
    case doFirst, schedule, delegate, eliminate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .doFirst: "Do First"
        case .schedule: "Schedule"
        case .delegate: "Delegate"
        case .eliminate: "Eliminate"
        }
    }

    var subtitle: String {
        switch self {
        case .doFirst: "Urgent · Important"
        case .schedule: "Not urgent · Important"
        case .delegate: "Urgent · Not important"
        case .eliminate: "Not urgent · Not important"
        }
    }

    var icon: String {
        switch self {
        case .doFirst: "flame.fill"
        case .schedule: "calendar"
        case .delegate: "arrowshape.turn.up.right.fill"
        case .eliminate: "archivebox"
        }
    }

    var color: Color {
        switch self {
        case .doFirst: Theme.wine
        case .schedule: Theme.wineDeep
        case .delegate: Theme.rose
        case .eliminate: Theme.mauve
        }
    }
}

extension Notification.Name {
    /// Posted by CalendarStore when saving a task re-issued its EventKit
    /// identifier (list moves can), so state keyed by task ID can migrate.
    static let taskIdentifierDidChange = Notification.Name("taskIdentifierDidChange")
}

/// Persists manual quadrant placements per reminder ID (UserDefaults, like
/// TemplateStore). One shared instance is injected app-wide so every
/// window/scene reads and writes the same placements. Overrides for deleted
/// reminders are a few bytes each and pruning could drop placements for tasks
/// in temporarily hidden lists, so they are deliberately kept.
final class MatrixStore: ObservableObject {
    @Published private(set) var overrides: [String: Int]

    private let defaults = UserDefaults.standard
    private static let key = "matrixOverrides"
    private var identifierObserver: NSObjectProtocol?

    init() {
        overrides = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        identifierObserver = NotificationCenter.default.addObserver(
            forName: .taskIdentifierDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let old = note.userInfo?["old"] as? String,
                  let new = note.userInfo?["new"] as? String,
                  let placement = self.overrides.removeValue(forKey: old) else { return }
            self.overrides[new] = placement
            self.defaults.set(self.overrides, forKey: Self.key)
        }
    }

    deinit {
        if let identifierObserver {
            NotificationCenter.default.removeObserver(identifierObserver)
        }
    }

    func manualQuadrant(for taskID: String) -> Quadrant? {
        overrides[taskID].flatMap(Quadrant.init(rawValue:))
    }

    /// Places a task in a quadrant; nil returns it to automatic placement.
    func place(_ taskID: String, in quadrant: Quadrant?) {
        if let quadrant {
            overrides[taskID] = quadrant.rawValue
        } else {
            overrides.removeValue(forKey: taskID)
        }
        defaults.set(overrides, forKey: Self.key)
    }
}

// MARK: - Dashboard tab

/// Productivity dashboard: today/week/overdue stats, an Eisenhower matrix the
/// user can file tasks into, and Today / Next 7 Days / To Be Completed lists.
struct DashboardTabView: View {
    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var matrix: MatrixStore
    @State private var today: Date = .now
    @State private var selectedQuadrant: Quadrant = .doFirst
    @State private var showingQuickAdd = false
    @State private var selectedTask: TaskItem?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !store.isDemo && store.reminderAccess != .authorized {
                        accessPrompt
                    } else {
                        content
                    }
                }
                .padding()
                .contentColumn()
            }
            .background(Color.white)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingQuickAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.wine)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add task")
                }
            }
            .sheet(isPresented: $showingQuickAdd) {
                QuickAddSheet(prefillKind: .task)
                    .largeSheet()
            }
            .sheet(item: $selectedTask) { task in
                TaskDetailSheet(task: task)
                    .mediumOrLargeSheet()
            }
            .onDayChange { today = .now }
        }
    }

    // MARK: - Access gating

    @ViewBuilder
    private var accessPrompt: some View {
        if store.reminderAccess == .notDetermined {
            AccessPromptCard(
                icon: "square.grid.2x2",
                title: "Connect Reminders",
                message: "The dashboard sorts your reminders into an importance × urgency matrix and daily plans. Connect Reminders to start prioritizing.",
                buttonTitle: "Connect"
            ) {
                Task { await store.requestAccess() }
            }
        } else {
            AccessPromptCard(
                icon: "square.grid.2x2",
                title: "Reminders Access Off",
                message: "Reminders access is turned off for Mars Calendar. Turn it on in Settings to plan your tasks here.",
                buttonTitle: "Open Settings"
            ) {
                Platform.openPrivacySettings()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let data = makeData()
        statsRow(data)
        matrixSection(data)
        quadrantList(data)
        if store.tasks.isEmpty {
            EmptyStateText(text: "No tasks to show — tap + and try 'todo Finish report tomorrow !!!'. Hidden task lists don't appear here.")
        } else {
            unsortedSection(data)
            todaySection(data)
            weekSection(data)
            backlogSection(data)
        }
    }

    // MARK: - Stats

    private func statsRow(_ data: DashboardData) -> some View {
        let todayCount = data.overdue.count + data.dueToday.filter { !$0.isCompleted }.count
        return HStack(spacing: 10) {
            statCard(count: todayCount, label: "to do today")
            statCard(count: data.week.count, label: "next 7 days")
            statCard(count: data.overdue.count, label: "overdue", highlighted: !data.overdue.isEmpty)
        }
    }

    private func statCard(count: Int, label: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(highlighted ? Color.white : Theme.wineDeep)
            Text(label)
                .font(.caption)
                .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(highlighted ? Theme.wine : Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(count == 1 ? "task" : "tasks") \(label)")
    }

    // MARK: - Matrix

    private func matrixSection(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Priority Matrix")
            HStack(spacing: 10) {
                axisLabel("Urgent")
                axisLabel("Not Urgent")
            }
            HStack(spacing: 10) {
                quadrantCard(.doFirst, count: data.count(in: .doFirst))
                quadrantCard(.schedule, count: data.count(in: .schedule))
            }
            HStack(spacing: 10) {
                quadrantCard(.delegate, count: data.count(in: .delegate))
                quadrantCard(.eliminate, count: data.count(in: .eliminate))
            }
            Text("Tasks with a due date or !! priority sort themselves — urgent means due within two days. File or re-file any task with its quadrant chip or context menu; your placements stick.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func quadrantCard(_ quadrant: Quadrant, count: Int) -> some View {
        let isSelected = quadrant == selectedQuadrant
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedQuadrant = quadrant }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: quadrant.icon)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                .foregroundStyle(isSelected ? Color.white : quadrant.color)
                Text(quadrant.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : Theme.wineDeep)
                Text(quadrant.subtitle)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isSelected ? quadrant.color : Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(quadrant.title): \(count) \(count == 1 ? "task" : "tasks")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func quadrantList(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let tasks = data.quadrants[selectedQuadrant] ?? []
            HStack(spacing: 8) {
                SectionHeader(title: selectedQuadrant.title)
                Text(selectedQuadrant.subtitle.lowercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if tasks.isEmpty {
                Text("Nothing filed here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(tasks) { task in
                    matrixRow(task)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func unsortedSection(_ data: DashboardData) -> some View {
        if !data.unsorted.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Unsorted", count: data.unsorted.count)
                Text("No due date or priority yet — file these into the matrix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(data.unsorted) { task in
                    matrixRow(task)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Task row with completion toggle and a trailing quadrant chip that opens
    /// the move menu.
    private func matrixRow(_ task: TaskItem) -> some View {
        let assigned = assignedQuadrant(for: task)
        return HStack(spacing: 10) {
            Button {
                store.toggleCompleted(task)
            } label: {
                Circle()
                    .strokeBorder(store.color(for: task.listID), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.title)")
            Button {
                selectedTask = task
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let detail = dueLine(for: task) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isOverdue(task) ? Theme.wine : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if task.priority > 0 {
                Text(task.priorityMarks)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
            }
            if task.hasRecurrence {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            quadrantMenu(for: task, assigned: assigned) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(assigned?.color ?? Color.gray, in: Circle())
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The move menu: four quadrants plus a return-to-automatic row when the
    /// task was manually placed.
    private func quadrantMenu<L: View>(for task: TaskItem, assigned: Quadrant?,
                                       @ViewBuilder label: () -> L) -> some View {
        Menu {
            quadrantMenuItems(for: task, assigned: assigned)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(assigned.map { "Filed in \($0.title) — move \(task.title)" }
            ?? "File \(task.title) in matrix")
    }

    @ViewBuilder
    private func quadrantMenuItems(for task: TaskItem, assigned: Quadrant?) -> some View {
        ForEach(Quadrant.allCases) { quadrant in
            Button {
                matrix.place(task.id, in: quadrant)
            } label: {
                Label(quadrant.title, systemImage: quadrant == assigned ? "checkmark" : quadrant.icon)
            }
        }
        if matrix.manualQuadrant(for: task.id) != nil {
            Divider()
            Button("Back to Automatic") {
                matrix.place(task.id, in: nil)
            }
        }
    }

    // MARK: - Task lists

    private func todaySection(_ data: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Today", count: data.overdue.count + data.dueToday.filter { !$0.isCompleted }.count)
            if data.overdue.isEmpty && data.dueToday.isEmpty {
                Text("Nothing due today — a clear runway.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(data.overdue) { task in
                    listRow(task, showsDate: true)
                }
                ForEach(data.dueToday) { task in
                    listRow(task, showsDate: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func weekSection(_ data: DashboardData) -> some View {
        if !data.week.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Next 7 Days", count: data.week.count)
                ForEach(data.week) { task in
                    listRow(task, showsDate: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func backlogSection(_ data: DashboardData) -> some View {
        if !data.backlog.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("To Be Completed", count: data.backlog.count)
                ForEach(data.backlog) { task in
                    listRow(task, showsDate: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            SectionHeader(title: title)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.wine, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private func listRow(_ task: TaskItem, showsDate: Bool) -> some View {
        Button {
            selectedTask = task
        } label: {
            TaskRow(task: task, color: store.color(for: task.listID), showsDate: showsDate) {
                store.toggleCompleted(task)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            quadrantMenuItems(for: task, assigned: assignedQuadrant(for: task))
        }
    }

    // MARK: - Classification & bucketing

    /// Manual placement wins; otherwise a task needs some signal (a due date
    /// or a priority) to place itself: urgency = overdue or due within ~48
    /// hours, importance = !!/!!!. No signal → unsorted, waiting to be filed.
    private func assignedQuadrant(for task: TaskItem) -> Quadrant? {
        if let manual = matrix.manualQuadrant(for: task.id) { return manual }
        guard task.due != nil || task.priority > 0 else { return nil }
        let urgent: Bool
        if let due = task.due,
           let horizon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: today)) {
            urgent = due < horizon
        } else {
            urgent = false
        }
        let important = task.priority >= 2
        switch (urgent, important) {
        case (true, true): return .doFirst
        case (false, true): return .schedule
        case (true, false): return .delegate
        case (false, false): return .eliminate
        }
    }

    private struct DashboardData {
        var quadrants: [Quadrant: [TaskItem]] = [:]
        var unsorted: [TaskItem] = []
        var overdue: [TaskItem] = []
        var dueToday: [TaskItem] = []
        var week: [TaskItem] = []
        var backlog: [TaskItem] = []

        func count(in quadrant: Quadrant) -> Int { quadrants[quadrant]?.count ?? 0 }
    }

    /// One pass over store.tasks buckets every section, then sorts each bucket.
    private func makeData() -> DashboardData {
        var data = DashboardData()
        let startToday = calendar.startOfDay(for: today)
        guard let weekEnd = calendar.date(byAdding: .day, value: 8, to: startToday) else { return data }

        for task in store.tasks {
            let dueToday = task.due.map { calendar.isDate($0, inSameDayAs: today) } ?? false
            if dueToday && !(store.hideCompleted && task.isCompleted) {
                data.dueToday.append(task)
            }
            guard !task.isCompleted else { continue }
            if let due = task.due {
                if due < startToday {
                    data.overdue.append(task)
                } else if !dueToday {
                    if due < weekEnd {
                        data.week.append(task)
                    } else {
                        data.backlog.append(task)
                    }
                }
            } else {
                data.backlog.append(task)
            }
            if let quadrant = assignedQuadrant(for: task) {
                data.quadrants[quadrant, default: []].append(task)
            } else {
                data.unsorted.append(task)
            }
        }

        data.dueToday = data.dueToday.filter { !$0.isCompleted } + data.dueToday.filter(\.isCompleted)
        data.overdue.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
        data.week.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        data.backlog = data.backlog.filter { $0.due != nil }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            + data.backlog.filter { $0.due == nil }
        for quadrant in data.quadrants.keys {
            data.quadrants[quadrant]?.sort { lhs, rhs in
                let l = lhs.due ?? .distantFuture
                let r = rhs.due ?? .distantFuture
                if l != r { return l < r }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return data
    }

    // MARK: - Row helpers

    private func isOverdue(_ task: TaskItem) -> Bool {
        guard let due = task.due, !task.isCompleted else { return false }
        return due < calendar.startOfDay(for: today)
    }

    private func dueLine(for task: TaskItem) -> String? {
        guard let due = task.due else { return nil }
        var parts: [String] = [Format.relativeDay(due) ?? Format.shortDate(due)]
        if task.hasDueTime { parts.append(Format.time(due)) }
        if isOverdue(task) { parts.append("overdue") }
        return parts.joined(separator: " · ")
    }
}

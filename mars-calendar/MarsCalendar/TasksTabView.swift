import SwiftUI

/// Fantastical-style dedicated tasks screen: Overdue / Today / Upcoming /
/// Someday sections plus a collapsible Completed section.
struct TasksTabView: View {
    @EnvironmentObject private var store: CalendarStore
    @State private var today: Date = .now
    @State private var showingQuickAdd = false
    @State private var selectedTask: TaskItem?
    @State private var showsCompleted = false

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
            }
            .background(Color.white)
            .navigationTitle("Tasks")
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
                icon: "checklist",
                title: "Connect Reminders",
                message: "Mars Calendar shows your reminders as tasks, right next to your events. Connect Reminders to see and check them off here.",
                buttonTitle: "Connect"
            ) {
                Task { await store.requestAccess() }
            }
        } else {
            AccessPromptCard(
                icon: "checklist",
                title: "Reminders Access Off",
                message: "Reminders access is turned off for Mars Calendar. Turn it on in Settings to see and manage your tasks here.",
                buttonTitle: "Open Settings"
            ) {
                Platform.openPrivacySettings()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        let overdue = store.overdueTasks
        let todays = todayTasks
        let upcoming = upcomingTasks
        let later = laterTasks
        let someday = somedayTasks
        let completed = completedTasks
        let showsCompletedSection = !store.hideCompleted && !completed.isEmpty

        if overdue.isEmpty && todays.isEmpty && upcoming.isEmpty && later.isEmpty && someday.isEmpty && !showsCompletedSection {
            EmptyStateText(text: "No tasks yet — tap + and try 'todo Pay rent Friday'.")
        } else {
            if !overdue.isEmpty {
                taskSection("Overdue", tasks: overdue, showsDate: true)
            }
            if !todays.isEmpty {
                taskSection("Today", tasks: todays, showsDate: false)
            }
            if !upcoming.isEmpty {
                taskSection("Upcoming", tasks: upcoming, showsDate: true)
            }
            if !later.isEmpty {
                taskSection("Later", tasks: later, showsDate: true)
            }
            if !someday.isEmpty {
                taskSection("Someday", tasks: someday, showsDate: false)
            }
            if showsCompletedSection {
                completedSection(completed)
            }
        }
    }

    private func taskSection(_ title: String, tasks: [TaskItem], showsDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            ForEach(tasks) { task in
                taskRow(task, showsDate: showsDate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func completedSection(_ completed: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsCompleted.toggle()
            } label: {
                HStack(spacing: 8) {
                    SectionHeader(title: "Completed")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.wine)
                        .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsCompleted ? "Hide completed tasks" : "Show completed tasks")
            if showsCompleted {
                ForEach(completed) { task in
                    taskRow(task, showsDate: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskRow(_ task: TaskItem, showsDate: Bool) -> some View {
        Button {
            selectedTask = task
        } label: {
            TaskRow(task: task, color: store.color(for: task.listID), showsDate: showsDate) {
                store.toggleCompleted(task)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    /// Tasks due today (minus anything already in Overdue), incomplete first.
    private var todayTasks: [TaskItem] {
        let overdueIDs = Set(store.overdueTasks.map(\.id))
        let due = store.tasks(on: today).filter { !overdueIDs.contains($0.id) }
        return due.filter { !$0.isCompleted } + due.filter(\.isCompleted)
    }

    /// Tasks due in the next 30 days after today, in day order.
    private var upcomingTasks: [TaskItem] {
        let start = calendar.startOfDay(for: today)
        var result: [TaskItem] = []
        for offset in 1...30 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            result.append(contentsOf: store.tasks(on: day))
        }
        return result
    }

    /// Dated tasks past the Upcoming horizon, so nothing dated ever vanishes from this tab.
    private var laterTasks: [TaskItem] {
        guard let horizon = calendar.date(byAdding: .day, value: 31, to: calendar.startOfDay(for: today)) else { return [] }
        return store.tasks.filter { task in
            guard let due = task.due, !task.isCompleted else { return false }
            return due >= horizon
        }
    }

    private var somedayTasks: [TaskItem] {
        store.undatedTasks.filter { !$0.isCompleted }
    }

    private var completedTasks: [TaskItem] {
        store.tasks.filter(\.isCompleted)
    }
}

import SwiftUI

/// Detail sheet for a task: read-only summary with an inline edit mode
/// (title, list, due date, priority, notes), completion toggle, and delete.
struct TaskDetailSheet: View {
    let task: TaskItem

    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var confirmingDelete = false

    @State private var editTitle: String
    @State private var editListID: String
    @State private var editHasDue: Bool
    @State private var editDue: Date
    @State private var editHasTime: Bool
    @State private var editPriority: Int
    @State private var editNotes: String

    private let calendar = Calendar.current

    init(task: TaskItem) {
        self.task = task
        _editTitle = State(initialValue: task.title)
        _editListID = State(initialValue: task.listID)
        _editHasDue = State(initialValue: task.due != nil)
        let fallback = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
        _editDue = State(initialValue: task.due ?? fallback)
        _editHasTime = State(initialValue: task.hasDueTime)
        _editPriority = State(initialValue: task.priority)
        _editNotes = State(initialValue: task.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing {
                        editContent
                    } else {
                        viewContent
                    }
                    deleteButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Task")
            .inlineNavigationBarTitle()
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetEditState()
                            isEditing = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveEdits() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Edit") { isEditing = true }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .tint(Theme.wine)
        .safeAreaInset(edge: .top) { CalendarMutationErrorBanner() }
        .mediumOrLargeSheet()
    }

    // MARK: - View mode

    @ViewBuilder private var viewContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.title3.weight(.bold))
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? Color.secondary : Theme.wineDeep)
            HStack(spacing: 6) {
                CalendarDot(color: store.color(for: task.listID))
                Text(store.calendarSource(task.listID)?.title ?? "List")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let due = task.due {
            DetailRow(icon: "calendar", title: Format.dayHeader(due), subtitle: dueSubtitle(for: due))
        }
        if task.priority > 0 {
            DetailRow(icon: "exclamationmark.circle", title: priorityName, trailing: task.priorityMarks)
        }
        if task.hasRecurrence {
            DetailRow(icon: "repeat", title: "Repeats")
        }
        if let notes = task.notes {
            Text(notes)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        completionButton
    }

    @ViewBuilder private var completionButton: some View {
        if task.isCompleted {
            WineOutlineButton(title: "Mark Incomplete", systemImage: "arrow.uturn.backward") {
                if store.toggleCompleted(task) { dismiss() }
            }
        } else {
            WineButton(title: "Mark Completed", systemImage: "checkmark.circle.fill") {
                if store.toggleCompleted(task) { dismiss() }
            }
        }
    }

    private func dueSubtitle(for due: Date) -> String? {
        var parts: [String] = []
        if let relative = Format.relativeDay(due) { parts.append(relative) }
        if task.hasDueTime { parts.append(Format.time(due)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var priorityName: String {
        switch task.priority {
        case 3: "High priority"
        case 2: "Medium priority"
        default: "Low priority"
        }
    }

    // MARK: - Edit mode

    @ViewBuilder private var editContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $editTitle)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            listMenu

            Toggle("Has due date", isOn: $editHasDue)
                .font(.subheadline.weight(.semibold))
                .tint(Theme.wine)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            if editHasDue {
                DatePicker("Date", selection: $editDue, displayedComponents: [.date])
                    .font(.subheadline.weight(.semibold))
                    .datePickerStyle(.compact)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

                Toggle("At a time", isOn: $editHasTime)
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.wine)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

                if editHasTime {
                    DatePicker("Time", selection: $editDue, displayedComponents: [.hourAndMinute])
                        .font(.subheadline.weight(.semibold))
                        .datePickerStyle(.compact)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Priority")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Priority", selection: $editPriority) {
                    Text("None").tag(0)
                    Text("!").tag(1)
                    Text("!!").tag(2)
                    Text("!!!").tag(3)
                }
                .pickerStyle(.segmented)
            }

            TextField("Notes", text: $editNotes, axis: .vertical)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3...6)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var listMenu: some View {
        Menu {
            ForEach(store.taskLists) { list in
                Button {
                    editListID = list.id
                } label: {
                    if list.id == editListID {
                        Label(list.title, systemImage: "checkmark")
                    } else {
                        Text(list.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                CalendarDot(color: store.color(for: editListID))
                Text(store.calendarSource(editListID)?.title ?? "List")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resetEditState() {
        editTitle = task.title
        editListID = task.listID
        editHasDue = task.due != nil
        let fallback = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
        editDue = task.due ?? fallback
        editHasTime = task.hasDueTime
        editPriority = task.priority
        editNotes = task.notes ?? ""
    }

    private func saveEdits() {
        var updated = task
        let title = editTitle.trimmingCharacters(in: .whitespaces)
        updated.title = title.isEmpty ? task.title : title
        updated.listID = editListID
        if editHasDue {
            updated.due = editHasTime ? editDue : calendar.startOfDay(for: editDue)
            updated.hasDueTime = editHasTime
        } else {
            updated.due = nil
            updated.hasDueTime = false
        }
        updated.priority = editPriority
        let notes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = notes.isEmpty ? nil : notes
        if store.save(task: updated) { dismiss() }
    }

    // MARK: - Delete

    private var deleteButton: some View {
        WineOutlineButton(title: "Delete Task", systemImage: "trash") {
            confirmingDelete = true
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if store.delete(task: task) { dismiss() }
            }
        }
    }
}

// MARK: - Row

/// Blush info row with a filled wine 34pt circle icon (suite row pattern).
private struct DetailRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.wine, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

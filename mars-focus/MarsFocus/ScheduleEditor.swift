import SwiftUI

/// Row for a queued one-time session, shown in the Calendar tab's Upcoming section.
struct UpcomingRow: View {
    let session: ScheduledSession
    let listNames: [String]
    let onCancel: () -> Void

    @State private var confirmingCancel = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.wine, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name ?? session.startAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.subheadline.weight(.semibold))
                    if session.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.wine)
                    }
                }
                if session.name != nil {
                    Text(session.startAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Format.duration(TimeInterval(session.minutes * 60))) · \(session.isBlockingEverything ? "All websites" : (listNames.isEmpty ? "No blocklists" : listNames.joined(separator: ", ")))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                confirmingCancel = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel scheduled session")
            .confirmationDialog(
                "Cancel this scheduled session?",
                isPresented: $confirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel Session", role: .destructive, action: onCancel)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Recurring rule editor

struct RuleEditorSheet: View {
    let existing: ScheduleRule?

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var selectedDays: Set<Int>
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var selectedLists: Set<UUID>
    @State private var isLocked: Bool
    @State private var didSave = false
    @State private var didLoadDefaults = false
    @State private var confirmingDelete = false

    private let calendar = Calendar.current

    init(existing: ScheduleRule?) {
        self.existing = existing
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        func time(minutes: Int) -> Date {
            // DST-safe: component matching keeps 9:00 as 9:00 even on days
            // that gain or lose an hour, so save round-trips don't drift.
            calendar.time(atMinutes: minutes, on: dayStart) ?? dayStart
        }
        _name = State(initialValue: existing?.name ?? "")
        _selectedDays = State(initialValue: existing?.weekdays ?? [2, 3, 4, 5, 6])
        _startTime = State(initialValue: time(minutes: existing?.startMinutes ?? 9 * 60))
        _endTime = State(initialValue: time(minutes: existing?.endMinutes ?? 11 * 60))
        _selectedLists = State(initialValue: Set(existing?.blocklistIDs ?? []))
        _isLocked = State(initialValue: existing?.isLocked ?? false)
    }

    private var startMinutes: Int { minutesOfDay(startTime) }
    private var endMinutes: Int { minutesOfDay(endTime) }

    private func minutesOfDay(_ date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var crossesMidnight: Bool { endMinutes <= startMinutes }

    private var canSave: Bool {
        !selectedDays.isEmpty && !selectedLists.isEmpty && startMinutes != endMinutes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameSection
                    daysSection
                    timeSection
                    listsSection
                    lockedToggle
                    if existing != nil {
                        deleteButton
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle(existing == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveAndDismiss)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: loadDefaults)
    }

    private func loadDefaults() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        if existing == nil, selectedLists.isEmpty {
            selectedLists = Set(blocklistStore.blocklists.map(\.id))
        }
    }

    private func saveAndDismiss() {
        guard !didSave, canSave else { return }
        didSave = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let orderedIDs = blocklistStore.blocklists.map(\.id).filter(selectedLists.contains)
        let rule = ScheduleRule(
            id: existing?.id ?? UUID(),
            name: trimmed.isEmpty ? "Focus schedule" : trimmed,
            weekdays: selectedDays,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            blocklistIDs: orderedIDs,
            isLocked: isLocked,
            isEnabled: existing?.isEnabled ?? true
        )
        if existing == nil {
            sessionStore.add(rule)
        } else {
            sessionStore.update(rule)
        }
        dismiss()
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            TextField("e.g. Morning Focus", text: $name)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Days")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            HStack(spacing: 8) {
                ForEach(ScheduleRule.orderedWeekdays(calendar: calendar), id: \.self) { weekday in
                    let isSelected = selectedDays.contains(weekday)
                    Button {
                        if isSelected {
                            selectedDays.remove(weekday)
                        } else {
                            selectedDays.insert(weekday)
                        }
                    } label: {
                        Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(isSelected ? Theme.wine : Theme.blush, in: Circle())
                            .foregroundStyle(isSelected ? .white : Theme.wineDeep)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                }
            }
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            VStack(spacing: 0) {
                DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 8)
                Divider()
                DatePicker("To", selection: $endTime, displayedComponents: .hourAndMinute)
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 8)
            }
            .tint(Theme.wine)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            if crossesMidnight && startMinutes != endMinutes {
                Text("Ends the next day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Block")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            if blocklistStore.blocklists.isEmpty {
                Text("No blocklists yet — create one in the Blocklists tab first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocklistStore.blocklists) { list in
                    BlocklistToggleRow(list: list, isSelected: selectedLists.contains(list.id)) {
                        if selectedLists.contains(list.id) {
                            selectedLists.remove(list.id)
                        } else {
                            selectedLists.insert(list.id)
                        }
                    }
                }
            }
        }
    }

    private var lockedToggle: some View {
        Toggle(isOn: $isLocked) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Locked mode")
                        .font(.subheadline.weight(.semibold))
                    Text("Sessions from this schedule can't be ended early.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Theme.wine)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Text("Delete Schedule")
                .font(.headline)
                .foregroundStyle(Theme.wine)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let existing {
                    sessionStore.delete(existing)
                }
                dismiss()
            }
        }
    }
}

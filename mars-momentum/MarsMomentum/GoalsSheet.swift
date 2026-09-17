import SwiftUI

/// Editor for per-category daily goals (duration or count) and the target weight.
struct GoalsSheet: View {
    @EnvironmentObject private var store: EntryStore
    @Environment(\.dismiss) private var dismiss

    struct Draft: Equatable {
        var enabled = false
        var kind: ValueKind = .duration
        var hours = 1
        var minutes = 0
        var numberText = ""
    }

    @State private var drafts: [TrackerCategory: Draft] = [:]
    @State private var originalDrafts: [TrackerCategory: Draft] = [:]
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach(TrackerCategory.allCases.filter(\.supportsDuration)) { category in
                    Section {
                        activityEditor(for: category)
                    } header: {
                        Label(category.title, systemImage: category.icon)
                    }
                }
                Section {
                    weightEditor
                } header: {
                    Label("Weight", systemImage: TrackerCategory.weight.icon)
                }
            }
            .navigationTitle("Goals")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveAndClose() }
                }
            }
        }
        .mediumOrLargeSheet()
        .onAppear(perform: loadDrafts)
    }

    @ViewBuilder
    private func activityEditor(for category: TrackerCategory) -> some View {
        let binding = draftBinding(for: category)
        Toggle("Daily goal", isOn: binding.enabled)
            .tint(Theme.wine)
        if binding.enabled.wrappedValue {
            Picker("Type", selection: binding.kind) {
                Text("Duration").tag(ValueKind.duration)
                Text("Count").tag(ValueKind.number)
            }
            .pickerStyle(.segmented)
            if binding.kind.wrappedValue == .duration {
                HStack {
                    Picker("Hours", selection: binding.hours) {
                        ForEach(0..<13, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    Picker("Minutes", selection: binding.minutes) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text("\($0) m").tag($0) }
                    }
                }
                .pickerStyle(.menu)
            } else {
                TextField("e.g. 2", text: binding.numberText)
                    .decimalPadKeyboard()
            }
        }
    }

    @ViewBuilder
    private var weightEditor: some View {
        let binding = draftBinding(for: .weight)
        Toggle("Target weight", isOn: binding.enabled)
            .tint(Theme.wine)
        if binding.enabled.wrappedValue {
            HStack {
                TextField("e.g. 70", text: binding.numberText)
                    .decimalPadKeyboard()
                if let unit = TrackerCategory.weight.numberUnit {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draftBinding(for category: TrackerCategory) -> Binding<Draft> {
        Binding(
            get: { drafts[category] ?? Draft() },
            set: { drafts[category] = $0 }
        )
    }

    private func loadDrafts() {
        guard !loaded else { return }
        loaded = true
        for category in TrackerCategory.allCases {
            var draft = Draft()
            if let goal = store.goals[category] {
                draft.enabled = true
                draft.kind = category == .weight ? .number : goal.kind
                if goal.kind == .duration {
                    let totalMinutes = Int(max(0, min(12 * 60 + 45, (goal.amount / 60).rounded())))
                    draft.hours = totalMinutes / 60
                    // Snap to the picker's quarter-hour steps.
                    draft.minutes = [0, 15, 30, 45].min { abs($0 - totalMinutes % 60) < abs($1 - totalMinutes % 60) } ?? 0
                } else {
                    // No grouping separators: "10,000" would re-parse as 10.0
                    // (or fail entirely) in saveAndClose.
                    draft.numberText = goal.amount.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
                }
            }
            drafts[category] = draft
        }
        originalDrafts = drafts
    }

    private func saveAndClose() {
        var goals: [TrackerCategory: Goal] = [:]
        for category in TrackerCategory.allCases {
            guard let draft = drafts[category], draft.enabled else { continue }
            // Goals from another client may exceed the picker range or use
            // non-quarter-hour minutes. Opening and saving must preserve them.
            if draft == originalDrafts[category], let existing = store.goals[category] {
                goals[category] = existing
                continue
            }
            if category != .weight && draft.kind == .duration {
                let seconds = Double(draft.hours * 3600 + draft.minutes * 60)
                if seconds > 0 {
                    goals[category] = Goal(kind: .duration, amount: seconds)
                } else if let existing = store.goals[category] {
                    // Enabled but invalid input: keep the old goal rather than
                    // silently deleting it. Unchecking the toggle is the way to remove.
                    goals[category] = existing
                }
            } else {
                let value = Double(draft.numberText.replacingOccurrences(of: ",", with: ".")) ?? 0
                if value > 0 && value <= 999_999 {
                    goals[category] = Goal(kind: .number, amount: value)
                } else if let existing = store.goals[category] {
                    goals[category] = existing
                }
            }
        }
        store.updateGoals(goals)
        dismiss()
    }
}

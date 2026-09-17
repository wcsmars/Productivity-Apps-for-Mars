import SwiftUI

/// Pomodoro: repeated work rounds with unblocked breaks between
/// them. The first round starts immediately; the rest are queued sessions.
struct PomodoroSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @Environment(\.dismiss) private var dismiss

    @State private var workMinutes = 25
    @State private var breakMinutes = 5
    @State private var rounds = 4
    @State private var selectedLists: Set<UUID> = []
    @State private var isLocked = false
    @State private var didStart = false
    @State private var didLoadDefaults = false

    private let workChoices = [15, 25, 45, 50]
    private let breakChoices = [5, 10, 15]
    private let roundChoices = [2, 3, 4, 6]

    private var canStart: Bool {
        !selectedLists.isEmpty && sessionStore.active == nil
    }

    private var totalText: String {
        let total = rounds * workMinutes + (rounds - 1) * breakMinutes
        return Format.duration(TimeInterval(total * 60))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if sessionStore.active != nil {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(Theme.wine)
                                Text("A session is already running — finish it before starting a Pomodoro.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                        }
                        chipsSection(title: "Work", choices: workChoices, selection: $workMinutes, suffix: "min")
                        chipsSection(title: "Break", choices: breakChoices, selection: $breakMinutes, suffix: "min")
                        chipsSection(title: "Rounds", choices: roundChoices, selection: $rounds, suffix: "×")
                        blocklistSection
                        lockedToggle
                        Text("Breaks are unblocked. Total: \(totalText). Remaining rounds appear under Upcoming on the Calendar, where they can be cancelled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                startButton
                    .padding([.horizontal, .bottom])
            }
            .background(Color.white)
            .navigationTitle("Pomodoro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: loadDefaults)
    }

    private func loadDefaults() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        let existing = Set(blocklistStore.blocklists.map(\.id))
        let last = sessionStore.lastUsedBlocklistIDs.filter(existing.contains)
        selectedLists = last.isEmpty ? existing : Set(last)
    }

    private func chipsSection(title: String, choices: [Int], selection: Binding<Int>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    let isOn = selection.wrappedValue == choice
                    Button {
                        selection.wrappedValue = choice
                    } label: {
                        Text("\(choice) \(suffix)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isOn ? Theme.wine : Theme.blush, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(isOn ? .white : Theme.wineDeep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var blocklistSection: some View {
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
                    Text("Work rounds can't be ended early.")
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

    private var startButton: some View {
        Button {
            guard !didStart, canStart else { return }
            didStart = true
            let orderedIDs = blocklistStore.blocklists.map(\.id).filter(selectedLists.contains)
            sessionStore.startPomodoro(blocklistIDs: orderedIDs, workMinutes: workMinutes,
                                       breakMinutes: breakMinutes, rounds: rounds, isLocked: isLocked)
            dismiss()
        } label: {
            Text("Start Pomodoro")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    canStart ? Theme.wine : Theme.wine.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .disabled(!canStart)
    }
}

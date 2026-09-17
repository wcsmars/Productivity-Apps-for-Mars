import SwiftUI

struct StartSessionSheet: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @Environment(\.dismiss) private var dismiss

    private enum StartMode: Hashable {
        case now, later
    }

    @State private var mode = StartMode.now
    @State private var hours = 0
    @State private var minutes = 30
    @State private var startAt = Date.now.addingTimeInterval(3600)
    @State private var selectedLists: Set<UUID> = []
    @State private var isLocked = false
    @State private var blockEverything = false
    @State private var didStart = false
    @State private var didLoadDefaults = false

    /// Pass a date (e.g. from the calendar) to open the sheet pre-set to
    /// schedule a session at that time instead of starting one now.
    init(presetStartAt: Date? = nil) {
        if let presetStartAt {
            _mode = State(initialValue: .later)
            _startAt = State(initialValue: max(presetStartAt, Date.now.addingTimeInterval(60)))
        }
    }

    /// Session duration ranges from 1 minute up to a full 24 hours.
    private var totalMinutes: Int { min(hours * 60 + minutes, SessionStore.maxSessionMinutes) }

    /// A session that auto-started (schedule/queue) while this sheet was open
    /// makes "start now" impossible — surface that instead of a silent no-op.
    private var blockedByRunningSession: Bool {
        mode == .now && sessionStore.active != nil
    }

    private var canStart: Bool {
        totalMinutes > 0 && (blockEverything || !selectedLists.isEmpty) && !blockedByRunningSession
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if sessionStore.active != nil {
                            runningSessionBanner
                        }
                        blocklistSection
                        durationSection
                        whenSection
                        lockedToggle
                    }
                    .padding()
                }
                startButton
                    .padding([.horizontal, .bottom])
            }
            .background(Color.white)
            .navigationTitle("New Session")
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

    // MARK: - Sections

    private var runningSessionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.wine)
            Text("A session is already running — you can still schedule one for later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private var blocklistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Block")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            Picker("Scope", selection: $blockEverything) {
                Text("My lists").tag(false)
                Text("Everything").tag(true)
            }
            .pickerStyle(.segmented)
            if blockEverything {
                Text("Blocks the entire web except your Website Exceptions (Settings → gear on the Focus tab). Apps picked with Screen Time in your lists aren't shielded in this mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let exceptions = sessionStore.websiteExceptions.count
                Text(exceptions > 0
                     ? "\(exceptions) site\(exceptions == 1 ? "" : "s") will stay reachable."
                     : "No exceptions yet — every website will be blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if blocklistStore.blocklists.isEmpty {
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

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            HStack(spacing: 0) {
                Picker("Hours", selection: $hours) {
                    ForEach(0..<25, id: \.self) { value in
                        Text("\(value) h").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                Picker("Minutes", selection: $minutes) {
                    ForEach(0..<60, id: \.self) { value in
                        Text("\(value) m").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .frame(height: 150)
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
            Picker("When", selection: $mode) {
                Text("Now").tag(StartMode.now)
                Text("Later").tag(StartMode.later)
            }
            .pickerStyle(.segmented)
            if mode == .later {
                DatePicker("Starts", selection: $startAt, in: Date.now...,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.wine)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
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
                    Text("You won't be able to end the session early.")
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
            // A second tap can land before the sheet finishes dismissing.
            guard !didStart, canStart else { return }
            didStart = true
            let orderedIDs = blockEverything ? []
                : blocklistStore.blocklists.map(\.id).filter(selectedLists.contains)
            switch mode {
            case .now:
                sessionStore.startSession(blocklistIDs: orderedIDs, minutes: totalMinutes,
                                          isLocked: isLocked, blocksEverything: blockEverything)
            case .later:
                sessionStore.scheduleSession(startAt: startAt, minutes: totalMinutes,
                                             blocklistIDs: orderedIDs, isLocked: isLocked,
                                             blocksEverything: blockEverything)
            }
            dismiss()
        } label: {
            Text(mode == .now ? "Start Session" : "Schedule Session")
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

/// Selectable blocklist row shared by the session sheet and the schedule editor.
struct BlocklistToggleRow: View {
    let list: Blocklist
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Theme.wine)
                    .frame(width: 34, height: 34)
                    .background(isSelected ? Theme.wine : Color.white, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.wine, lineWidth: isSelected ? 0 : 1.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(list.itemSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.wine : Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

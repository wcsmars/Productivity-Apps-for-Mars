import SwiftUI

struct FocusTabView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @State private var showingStartSheet = false
    @State private var showingPomodoro = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let session = sessionStore.active {
                        ActiveSessionView(session: session)
                    } else {
                        idleContent
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Mars Focus")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.wine)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingStartSheet) {
                StartSessionSheet()
            }
            .sheet(isPresented: $showingPomodoro) {
                PomodoroSheet()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
            .onAppear {
                #if DEBUG
                // Launch-argument overrides so UI verification can screenshot sheets.
                if CommandLine.arguments.contains("-openStartSheet") { showingStartSheet = true }
                if CommandLine.arguments.contains("-openPomodoro") { showingPomodoro = true }
                if CommandLine.arguments.contains("-openSettingsSheet") { showingSettings = true }
                #endif
            }
        }
    }

    // MARK: - Idle state

    private var idleContent: some View {
        VStack(spacing: 20) {
            // sessionStore.now is republished every tick, so this never shows
            // a window that has already started or been consumed.
            if let upcoming = sessionStore.nextUpcoming(after: sessionStore.now) {
                upNextCard(upcoming)
            }
            quickStartGrid
            customSessionButton
            pomodoroButton
        }
    }

    private func upNextCard(_ upcoming: UpcomingSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.wine, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Up next · \(upcoming.title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.wineDeep)
                Text("\(upcoming.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(upcoming.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    fileprivate struct QuickStart: Identifiable {
        let minutes: Int
        let title: String
        let icon: String
        let color: Color
        let isOutlined: Bool
        var id: Int { minutes }
    }

    private let quickStarts: [QuickStart] = [
        QuickStart(minutes: 15, title: "15 min", icon: "hare.fill", color: Theme.rose, isOutlined: false),
        QuickStart(minutes: 30, title: "30 min", icon: "timer", color: Theme.wine, isOutlined: false),
        QuickStart(minutes: 60, title: "1 hour", icon: "hourglass", color: Theme.wineDeep, isOutlined: false),
        QuickStart(minutes: 120, title: "2 hours", icon: "mountain.2.fill", color: Theme.wine, isOutlined: true),
    ]

    private var quickStartGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(quickStarts) { quick in
                Button {
                    startQuickSession(minutes: quick.minutes)
                } label: {
                    QuickStartCard(quick: quick, subtitle: quickStartSubtitle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Last-used blocklists when they still exist, otherwise every list.
    private var quickStartIDs: [UUID] {
        let existing = Set(blocklistStore.blocklists.map(\.id))
        let last = sessionStore.lastUsedBlocklistIDs.filter(existing.contains)
        return last.isEmpty ? blocklistStore.blocklists.map(\.id) : last
    }

    private var quickStartSubtitle: String {
        let count = quickStartIDs.count
        guard count > 0 else { return "No blocklists" }
        return "\(count) blocklist\(count == 1 ? "" : "s")"
    }

    private func startQuickSession(minutes: Int) {
        let ids = quickStartIDs
        guard !ids.isEmpty else {
            showingStartSheet = true
            return
        }
        sessionStore.startSession(blocklistIDs: ids, minutes: minutes, isLocked: false)
    }

    private var customSessionButton: some View {
        Button {
            showingStartSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                Text("Custom Session")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var pomodoroButton: some View {
        Button {
            showingPomodoro = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                Text("Pomodoro")
            }
            .font(.headline)
            .foregroundStyle(Theme.wine)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.wine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct QuickStartCard: View {
    let quick: FocusTabView.QuickStart
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: quick.icon)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(0.6)
            }
            Spacer(minLength: 0)
            Text(quick.title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .opacity(0.85)
        }
        .foregroundStyle(quick.isOutlined ? Theme.wine : .white)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(
            quick.isOutlined ? Color.white : quick.color,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.wine, lineWidth: quick.isOutlined ? 1.5 : 0)
        )
    }
}

// MARK: - Active session

struct ActiveSessionView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var blocklistStore: BlocklistStore
    @EnvironmentObject private var screenTime: ScreenTimeManager
    @EnvironmentObject private var sounds: SoundscapePlayer
    let session: ActiveSession

    @State private var confirmingEnd = false
    @State private var confirmingExtend = false

    private var remaining: TimeInterval {
        max(0, session.endsAt.timeIntervalSince(sessionStore.now))
    }

    private var progress: Double {
        guard session.plannedDuration > 0 else { return 0 }
        return min(1, max(0, remaining / session.plannedDuration))
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            countdownRing
            soundRow
            blockedLists
            controls
        }
    }

    /// Ambient focus sounds synthesized locally, with no downloads.
    private var soundRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.wine)
            ForEach(SoundscapePlayer.Sound.allCases) { sound in
                let isOn = sounds.current == sound
                Button {
                    sounds.select(sound)
                } label: {
                    Text(sound.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isOn ? Theme.wine : Theme.blush, in: Capsule())
                        .foregroundStyle(isOn ? .white : Theme.wineDeep)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(session.scheduleName ?? "You're in a focus session")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            if session.isLocked {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Locked")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.wine, in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(Theme.blush, lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.wine, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            VStack(spacing: 4) {
                Text(Format.countdown(remaining))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.wine)
                    .monospacedDigit()
                Text("Ends at \(session.endsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 230, height: 230)
        .padding(.vertical, 8)
    }

    private var blockedLists: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocking")
                .font(.headline)
                .foregroundStyle(Theme.wineDeep)
                .frame(maxWidth: .infinity, alignment: .leading)
            let lists = blocklistStore.blocklists(withIDs: session.blocklistIDs)
            if session.isBlockingEverything {
                let exceptions = sessionStore.websiteExceptions.count
                blockedRow(name: "Everything on the web",
                           summary: exceptions > 0
                               ? "except \(exceptions) allowed site\(exceptions == 1 ? "" : "s")"
                               : "no exceptions",
                           isShielded: screenTime.isAuthorized)
            } else if lists.isEmpty {
                // The lists were deleted mid-session; fall back to the names
                // snapshot, keyed by position since names may repeat.
                ForEach(Array(session.blocklistNames.enumerated()), id: \.offset) { _, name in
                    blockedRow(name: name, summary: nil, isShielded: false)
                }
                if session.blocklistNames.isEmpty {
                    Text("Nothing is being blocked in this session.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(lists) { list in
                    // Picker selections are shielded; typed/keyword domains go
                    // through the web-content filter — both count as enforced.
                    blockedRow(name: list.name, summary: list.itemSummary,
                               isShielded: screenTime.isAuthorized &&
                                   (list.screenTimeItemCount > 0 || !list.blockedDomains.isEmpty))
                }
            }
        }
    }

    /// The shield checkmark appears only when the row genuinely contributes
    /// OS-level blocking — catalog apps are tracked, not enforced; picker
    /// selections and typed/keyword domains (web-content filter) are.
    private func blockedRow(name: String, summary: String?, isShielded: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.wine, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isShielded {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.wine)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                // Time added to a locked session can't be taken back — confirm first.
                if session.isLocked {
                    confirmingExtend = true
                } else {
                    sessionStore.extendActiveSession(byMinutes: 15)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add 15 min")
                }
                .font(.headline)
                .foregroundStyle(Theme.wine)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.wine, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Add 15 minutes to this locked session? You won't be able to end it any sooner.",
                isPresented: $confirmingExtend,
                titleVisibility: .visible
            ) {
                Button("Add 15 min") {
                    sessionStore.extendActiveSession(byMinutes: 15)
                }
            }

            if session.isLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Locked until \(session.endsAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            } else {
                Button {
                    confirmingEnd = true
                } label: {
                    Text("End Session")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
                }
                .confirmationDialog(
                    "End this session early?",
                    isPresented: $confirmingEnd,
                    titleVisibility: .visible
                ) {
                    Button("End Session", role: .destructive) {
                        sessionStore.endActiveSessionEarly()
                    }
                }
            }
        }
    }
}

import SwiftUI
import Combine

struct RootView: View {
    enum Tab: Int {
        case focus, blocklists, calendar, history, coach
    }

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var sounds: SoundscapePlayer
    @State private var selectedTab: Tab

    // static: RootView is re-created whenever the app body re-evaluates, and an
    // instance property would build (and resubscribe) a fresh timer publisher
    // each time; the shared one connects exactly once for the process lifetime.
    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init() {
        var initial = Tab.focus
        #if DEBUG
        // Launch-argument overrides so UI verification can screenshot each tab.
        if CommandLine.arguments.contains("-openBlocklists") { initial = .blocklists }
        if CommandLine.arguments.contains("-openCalendar") { initial = .calendar }
        if CommandLine.arguments.contains("-openSchedule") { initial = .calendar }
        if CommandLine.arguments.contains("-openHistory") { initial = .history }
        if CommandLine.arguments.contains("-openCoach") { initial = .coach }
        #endif
        _selectedTab = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            FocusTabView()
                .tabItem { Label("Focus", systemImage: "shield.fill") }
                .tag(Tab.focus)
            BlocklistsTabView()
                .tabItem { Label("Blocklists", systemImage: "hand.raised.fill") }
                .tag(Tab.blocklists)
            CalendarTabView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            HistoryTabView()
                .tabItem { Label("History", systemImage: "square.grid.3x3.fill") }
                .tag(Tab.history)
            CoachTabView()
                .tabItem { Label("Coach", systemImage: "sparkles") }
                .tag(Tab.coach)
        }
        .tint(Theme.wine)
        .onReceive(Self.ticker) { _ in sessionStore.tick() }
        .onDayChange { sessionStore.tick() }
        // Focus sounds belong to the session — silence them when it ends.
        .onChange(of: sessionStore.active?.id) { _, id in
            if id == nil { sounds.stop() }
        }
    }
}

import SwiftUI

@main
struct MarsFocusApp: App {
    @StateObject private var blocklistStore: BlocklistStore
    @StateObject private var sessionStore: SessionStore
    @StateObject private var screenTime: ScreenTimeManager
    @StateObject private var coach: CoachStore
    @StateObject private var sounds = SoundscapePlayer()

    init() {
        let screenTime = ScreenTimeManager()
        let blocklists = BlocklistStore()
        let sessions = SessionStore(blocklistStore: blocklists, screenTime: screenTime)
        let coach = CoachStore()
        #if DEBUG
        if CommandLine.arguments.contains("-seedDemoData") { sessions.seedDemoData() }
        if CommandLine.arguments.contains("-demoActiveSession") { sessions.startDemoActiveSession() }
        if CommandLine.arguments.contains("-demoCoach") { coach.seedDemoConversation() }
        // Writes the exact enforcement plan (per-list domains, screen-time item
        // counts, exceptions) to Documents/shield-plan.txt so automated tests
        // can assert the blocking logic without Family Controls authorization.
        if CommandLine.arguments.contains("-dumpShieldPlan") {
            var lines = blocklists.blocklists.map { list in
                "LIST \(list.name) | apps=\(list.appIDs.joined(separator: ",")) | keywords=\(list.keywords.joined(separator: ",")) | domains=\(list.blockedDomains.joined(separator: ",")) | screenTimeItems=\(list.screenTimeItemCount)"
            }
            lines.append("EXCEPTIONS | \(sessions.websiteExceptions.joined(separator: ","))")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("shield-plan.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
        _blocklistStore = StateObject(wrappedValue: blocklists)
        _sessionStore = StateObject(wrappedValue: sessions)
        _screenTime = StateObject(wrappedValue: screenTime)
        _coach = StateObject(wrappedValue: coach)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(blocklistStore)
                .environmentObject(sessionStore)
                .environmentObject(screenTime)
                .environmentObject(coach)
                .environmentObject(sounds)
                .preferredColorScheme(.light)
        }
    }
}

import SwiftUI

@main
struct MarsMomentumApp: App {
    @StateObject private var store: EntryStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = EntryStore()
        #if DEBUG
        if CommandLine.arguments.contains("-seedDemoData") {
            store.seedDemoData()
        }
        // Headless UI verification: -syncServer URL -syncUser NAME -syncPass PASS
        if let server = Self.argument(after: "-syncServer"),
           let user = Self.argument(after: "-syncUser"),
           let pass = Self.argument(after: "-syncPass") {
            Task { @MainActor in
                _ = await store.signIn(serverText: server, username: user, password: pass, creating: false)
            }
        }
        #endif
        _store = StateObject(wrappedValue: store)
    }

    #if DEBUG
    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            rootContent
        }
        .defaultSize(width: 540, height: 900)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.syncNow() } }
        }
        #else
        WindowGroup {
            rootContent
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.syncNow() } }
        }
        #endif
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(store)
            .preferredColorScheme(.light)
    }
}

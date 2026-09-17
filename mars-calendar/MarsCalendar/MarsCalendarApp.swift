import SwiftUI

@main
struct MarsCalendarApp: App {
    @StateObject private var store: CalendarStore
    @StateObject private var weather: WeatherService
    /// Shared so every window/scene sees the same matrix placements.
    @StateObject private var matrix = MatrixStore()

    init() {
        #if DEBUG
        let demo = CommandLine.arguments.contains("-seedDemoData")
        let store = CalendarStore(demo: demo)
        let weather = WeatherService(demo: demo)
        // Month-view option presets for UI verification. Applied here — once
        // per process — so re-created views can't revert menu changes mid-run;
        // any -month* arg deterministically resets the whole option set.
        let args = CommandLine.arguments
        if args.contains(where: { $0.hasPrefix("-month") }) {
            let defaults = UserDefaults.standard
            defaults.set(args.contains("-monthEvents") ? "events" : "dots", forKey: "monthDisplay")
            defaults.set(args.contains("-monthWeeks2") ? 2 : args.contains("-monthWeeks4") ? 4 : 0,
                         forKey: "monthWeeks")
            defaults.set(args.contains("-monthWeekNumbers"), forKey: "monthWeekNumbers")
            defaults.set(false, forKey: "monthWeekendShading")
            defaults.set(true, forKey: "monthShowsTasks")
        }
        #else
        let store = CalendarStore()
        let weather = WeatherService()
        #endif
        _store = StateObject(wrappedValue: store)
        _weather = StateObject(wrappedValue: weather)
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            rootContent
        }
        .defaultSize(width: 1000, height: 760)
        #else
        WindowGroup {
            rootContent
        }
        #endif
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(store)
            .environmentObject(weather)
            .environmentObject(matrix)
            .preferredColorScheme(.light)
    }
}

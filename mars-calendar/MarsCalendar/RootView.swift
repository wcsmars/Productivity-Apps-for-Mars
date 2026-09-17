import SwiftUI

struct RootView: View {
    private enum Tab: Int { case calendar, dashboard, tasks, search }

    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var weather: WeatherService
    @State private var selectedTab: Tab

    init() {
        var initial = Tab.calendar
        #if DEBUG
        // Launch-argument overrides so UI verification can screenshot each tab.
        if CommandLine.arguments.contains("-openDashboard") { initial = .dashboard }
        if CommandLine.arguments.contains("-openTasks") { initial = .tasks }
        if CommandLine.arguments.contains("-openSearch") { initial = .search }
        #endif
        _selectedTab = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CalendarTabView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            DashboardTabView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.dashboard)
            TasksTabView()
                .tabItem { Label("Tasks", systemImage: "checkmark.circle.fill") }
                .tag(Tab.tasks)
            SearchTabView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        .tint(Theme.wine)
        .safeAreaInset(edge: .top) { CalendarMutationErrorBanner() }
        .onDayChange {
            store.refresh()
            weather.refreshIfStale()
        }
    }
}

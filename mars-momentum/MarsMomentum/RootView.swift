import SwiftUI

struct RootView: View {
    enum Tab: Int {
        case today, calendar, progress
    }

    @State private var selectedTab: Tab

    init() {
        var initial = Tab.today
        #if DEBUG
        // Launch-argument overrides so UI verification can screenshot each tab.
        if CommandLine.arguments.contains("-openCalendar") { initial = .calendar }
        if CommandLine.arguments.contains("-openProgress") { initial = .progress }
        #endif
        _selectedTab = State(initialValue: initial)
    }

    var body: some View {
        #if os(macOS)
        // The automatic TabView style on macOS is the legacy gray top-tab strip,
        // which ignores the tint — use the app's own chip chrome instead.
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tabChip("Today", icon: "sun.max.fill", tab: .today, key: "1")
                tabChip("Calendar", icon: "calendar", tab: .calendar, key: "2")
                tabChip("Progress", icon: "square.grid.3x3.fill", tab: .progress, key: "3")
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            Divider()
            // All three views stay alive so their @State (calendar mode, filters,
            // displayed month) survives tab switches, matching iOS TabView behavior.
            ZStack {
                tabContent(.today) { TodayView() }
                tabContent(.calendar) { CalendarTabView() }
                tabContent(.progress) { ProgressTabView() }
            }
        }
        .background(Color.white)
        #else
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
                .tag(Tab.today)
            CalendarTabView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "square.grid.3x3.fill") }
                .tag(Tab.progress)
        }
        .tint(Theme.wine)
        #endif
    }

    #if os(macOS)
    private func tabContent<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
    }

    private func tabChip(_ title: String, icon: String, tab: Tab, key: KeyEquivalent) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(selectedTab == tab ? Theme.wine : Theme.blush, in: Capsule())
            .foregroundStyle(selectedTab == tab ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.wineDeep))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
    }
    #endif
}

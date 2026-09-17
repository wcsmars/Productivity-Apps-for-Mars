import SwiftUI

/// The app's signature main screen: month/year large title, DayTicker under it,
/// and either the combined event list or the month grid beneath, with a floating
/// quick-add button. Fantastical's anatomy in the suite's wine/white language.
struct CalendarTabView: View {
    private enum ViewMode: CaseIterable {
        case list, week, month, year

        var title: String {
            switch self {
            case .list: "List"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            }
        }

        var icon: String {
            switch self {
            case .list: "list.bullet"
            case .week: "calendar.day.timeline.left"
            case .month: "calendar"
            case .year: "square.grid.3x3"
            }
        }
    }

    @EnvironmentObject private var store: CalendarStore

    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var today = Calendar.current.startOfDay(for: .now)
    @State private var viewMode: ViewMode
    @State private var showingQuickAdd = false
    @State private var showingSettings = false
    @State private var showingSets = false
    @State private var showingAddCalendar = false
    @State private var showingAddAccount = false

    private let calendar = Calendar.current

    init() {
        var mode = ViewMode.list
        #if DEBUG
        if CommandLine.arguments.contains("-openMonth") { mode = .month }
        if CommandLine.arguments.contains("-openWeek") { mode = .week }
        if CommandLine.arguments.contains("-openYear") { mode = .year }
        #endif
        _viewMode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isDemo || store.eventAccess == .authorized {
                    VStack(spacing: 0) {
                        DayTicker(selectedDay: $selectedDay)
                        switch viewMode {
                        case .list:
                            EventListView(selectedDay: $selectedDay)
                        case .week:
                            WeekView(selectedDay: $selectedDay)
                        case .month:
                            MonthGridView(selectedDay: $selectedDay) { day in
                                selectedDay = day
                                withAnimation { viewMode = .week }
                            }
                        case .year:
                            YearView(selectedDay: $selectedDay) { month in
                                withAnimation { viewMode = .month }
                                selectedDay = calendar.isDate(today, equalTo: month, toGranularity: .month)
                                    ? today
                                    : calendar.startOfMonth(for: month)
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { newItemButton }
                } else {
                    accessGate
                }
            }
            .background(Color.white)
            .navigationTitle(selectedDay.formatted(.dateTime.month(.wide).year()))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !calendar.isDate(selectedDay, inSameDayAs: today) {
                        Button {
                            withAnimation { selectedDay = today }
                        } label: {
                            Text("Today")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.wine)
                        }
                    }
                    Menu {
                        Picker("View", selection: $viewMode.animation()) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Label(mode.title, systemImage: mode.icon).tag(mode)
                            }
                        }
                        Section("Calendar Sets") {
                            Button {
                                store.activateAllCalendars()
                            } label: {
                                if store.activeSetID == nil {
                                    Label("All Calendars", systemImage: "checkmark")
                                } else {
                                    Text("All Calendars")
                                }
                            }
                            ForEach(store.calendarSets) { set in
                                Button {
                                    store.activateSet(set)
                                } label: {
                                    if store.activeSetID == set.id {
                                        Label(set.name, systemImage: "checkmark")
                                    } else {
                                        Text(set.name)
                                    }
                                }
                            }
                            Button("Manage Sets…") { showingSets = true }
                        }
                        Section {
                            Button("Add Calendar…") { showingAddCalendar = true }
                            Button("Add Account…") { showingAddAccount = true }
                        }
                    } label: {
                        Image(systemName: viewMode.icon)
                            .foregroundStyle(Theme.wine)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("View and calendars menu")
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.wine)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingQuickAdd) {
                QuickAddSheet(prefillDay: selectedDay)
                    .largeSheet()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
                    .largeSheet()
            }
            .sheet(isPresented: $showingSets) { CalendarSetsSheet() }
            .sheet(isPresented: $showingAddCalendar) { AddCalendarSheet() }
            .sheet(isPresented: $showingAddAccount) { AddAccountSheet() }
            .onChange(of: selectedDay) { _, newValue in
                store.ensureWindowContains(newValue)
            }
            .onDayChange {
                today = Calendar.current.startOfDay(for: .now)
            }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("-openQuickAdd") { showingQuickAdd = true }
                if CommandLine.arguments.contains("-openSettingsSheet") { showingSettings = true }
                #endif
            }
        }
    }

    // MARK: - Pieces

    /// Floating quick-add button, visible in both list and month modes.
    private var newItemButton: some View {
        Button {
            showingQuickAdd = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.wine, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New item")
        .padding(20)
    }

    /// Replaces the ticker + list when calendar access is missing.
    private var accessGate: some View {
        ScrollView {
            VStack(spacing: 20) {
                if store.eventAccess == .notDetermined {
                    AccessPromptCard(
                        icon: "calendar.badge.plus",
                        title: "Connect Your Calendar",
                        message: "Mars Calendar shows your events and lets you add new ones once it can read your calendar. It has no server of its own: events are read from and saved to your calendar accounts.",
                        buttonTitle: "Connect"
                    ) {
                        Task { await store.requestAccess() }
                    }
                } else {
                    AccessPromptCard(
                        icon: "calendar.badge.exclamationmark",
                        title: "Calendar Access Denied",
                        message: "Calendar access is turned off for Mars Calendar. Enable it in Settings to see your schedule and add events.",
                        buttonTitle: "Open Settings"
                    ) {
                        Platform.openPrivacySettings()
                    }
                }
            }
            .padding()
        }
        .background(Color.white)
    }
}

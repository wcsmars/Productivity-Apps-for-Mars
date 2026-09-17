import SwiftUI

/// Fantastical-style settings essentials in the suite idiom: access status,
/// defaults for new items, per-calendar visibility, and task behavior.
struct SettingsSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var weather: WeatherService
    @Environment(\.dismiss) private var dismiss
    @State private var showingSets = false
    @State private var showingAddCalendar = false
    @State private var showingAddAccount = false

    private let durationChoices = [15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accessSection
                    newItemsSection
                    calendarsSection
                    managementSection
                    tasksSection
                    weatherSection
                    aboutSection
                }
                .padding()
                .contentColumn()
            }
            .background(Color.white)
            .navigationTitle("Settings")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .largeSheet()
    }

    // MARK: - Access

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Access")
            statusRow(icon: "calendar", title: "Calendars", access: store.eventAccess)
            statusRow(icon: "checklist", title: "Reminders", access: store.reminderAccess)
            if !store.isDemo {
                if store.eventAccess == .notDetermined || store.reminderAccess == .notDetermined {
                    WineButton(title: "Connect") {
                        Task { await store.requestAccess() }
                    }
                }
                if store.eventAccess == .denied || store.reminderAccess == .denied {
                    WineOutlineButton(title: "Open Settings") {
                        Platform.openPrivacySettings()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(icon: String, title: String, access: CalendarStore.AccessState) -> some View {
        let connected = store.isDemo || access == .authorized
        let subtitle: String = if connected {
            "Connected"
        } else if access == .denied {
            "Access denied"
        } else {
            "Not connected"
        }
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(connected ? .white : Theme.wine)
                .frame(width: 34, height: 34)
                .background(connected ? Theme.wine : Color.white, in: Circle())
                .overlay(
                    Circle().strokeBorder(Theme.wine, lineWidth: connected ? 0 : 1.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - New items

    private var newItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "New Items")
            HStack(spacing: 12) {
                Text("Default Calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(store.writableCalendars) { source in
                        Button {
                            store.defaultCalendarID = source.id
                        } label: {
                            HStack {
                                CalendarDot(color: source.color)
                                Text(source.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let selected = store.defaultCalendar {
                            CalendarDot(color: selected.color)
                            Text(selected.title)
                        } else {
                            Text("None")
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 12) {
                Text("Default Duration")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(durationChoices, id: \.self) { minutes in
                        Button(durationLabel(minutes)) {
                            store.defaultDurationMinutes = minutes
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(durationLabel(store.defaultDurationMinutes))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Calendars

    private var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Calendars")
            if store.calendars.isEmpty {
                EmptyStateText(text: "No calendars yet — connect access above to see them here.")
            } else {
                ForEach(store.calendars) { source in
                    visibilityRow(for: source)
                }
            }
            SectionHeader(title: "Task Lists")
                .padding(.top, 4)
            if store.taskLists.isEmpty {
                EmptyStateText(text: "No task lists yet — connect Reminders to see them here.")
            } else {
                ForEach(store.taskLists) { source in
                    visibilityRow(for: source)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Management & weather

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            managementRow(icon: "plus.circle", title: "Add Calendar", subtitle: "Create a calendar or task list in any account") {
                showingAddCalendar = true
            }
            managementRow(icon: "at", title: "Add Account", subtitle: "Google, Exchange, iCloud & holiday calendars") {
                showingAddAccount = true
            }
            managementRow(icon: "square.stack.3d.up", title: "Calendar Sets", subtitle: store.activeSet.map { "Active: \($0.name)" } ?? "Group calendars and switch in one tap") {
                showingSets = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingSets) { CalendarSetsSheet() }
        .sheet(isPresented: $showingAddCalendar) { AddCalendarSheet() }
        .sheet(isPresented: $showingAddAccount) { AddAccountSheet() }
    }

    private func managementRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 34, height: 34)
                    .background(Color.white, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.wine, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.wine)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Weather")
            HStack(spacing: 12) {
                Text("Show weather in the list")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: $weather.enabled)
                    .labelsHidden()
                    .tint(Theme.wine)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            if let status = weather.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.wine)
            }
            Text("Forecast by Open-Meteo using your approximate location, fetched only while weather is on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func visibilityRow(for source: CalendarSource) -> some View {
        HStack(spacing: 12) {
            CalendarDot(color: source.color)
            Text(source.title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Toggle("", isOn: Binding(
                get: { !store.hiddenCalendarIDs.contains(source.id) },
                set: { store.setCalendar(source.id, hidden: !$0) }
            ))
            .labelsHidden()
            .tint(Theme.wine)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Tasks & about

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Tasks")
            HStack(spacing: 12) {
                Text("Hide completed tasks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: $store.hideCompleted)
                    .labelsHidden()
                    .tint(Theme.wine)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")
            Text("Mars Calendar is part of Productivity Apps for Mars, alongside Mars Momentum and Mars Focus. Designed for Mars with a shared wine-red and white theme.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        if minutes == 60 { return "1 hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

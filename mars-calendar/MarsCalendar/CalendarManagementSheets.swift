import SwiftUI

// MARK: - Calendar Sets

/// Fantastical-style Calendar Sets: named visibility groups the user can swap
/// between in one tap. "All Calendars" is the implicit set on top.
struct CalendarSetsSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var newSetName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    setsSection
                    saveSection
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Calendar Sets")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .largeSheet()
    }

    // MARK: Sets

    private var setsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sets")
            allCalendarsRow
            if store.calendarSets.isEmpty {
                EmptyStateText(text: "No sets yet — arrange your calendars, then save the view below.")
            } else {
                ForEach(store.calendarSets) { set in
                    SetRow(
                        name: set.name,
                        countText: countText(for: set),
                        isActive: store.activeSetID == set.id,
                        onActivate: { store.activateSet(set) },
                        onDelete: { store.deleteSet(set) }
                    )
                }
            }
            Text("Activating a set swaps which calendars and lists are visible everywhere. Hand-toggling a calendar afterwards steps outside the set.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allCalendarsRow: some View {
        let isActive = store.activeSetID == nil && store.hiddenCalendarIDs.isEmpty
        return Button {
            store.activateAllCalendars()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isActive ? .white : Theme.wine)
                    .frame(width: 34, height: 34)
                    .background(isActive ? Theme.wine : Color.white, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.wine, lineWidth: isActive ? 0 : 1.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Calendars")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Every calendar and list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.wine)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func countText(for set: CalendarSet) -> String {
        let all = Set(store.calendars.map(\.id)).union(store.taskLists.map(\.id))
        guard !all.isEmpty else { return "\(set.visibleIDs.count) calendars" }
        return "\(set.visibleIDs.intersection(all).count) of \(all.count) shown"
    }

    // MARK: Save current view

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Save Current View")
            Text("Hide or show calendars in Settings first, then keep the arrangement as a set.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Set name — try 'Work' or 'Weekend'", text: $newSetName)
                .font(.subheadline.weight(.semibold))
                .onSubmit(saveCurrentView)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            WineButton(title: "Save Current View as Set", systemImage: "square.grid.2x2") {
                saveCurrentView()
            }
            .disabled(trimmedSetName.isEmpty)
            .opacity(trimmedSetName.isEmpty ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmedSetName: String {
        newSetName.trimmingCharacters(in: .whitespaces)
    }

    private func saveCurrentView() {
        guard !trimmedSetName.isEmpty else { return }
        store.saveCurrentAsSet(named: trimmedSetName)
        newSetName = ""
    }
}

/// One saved set: activate on tap, delete via the trailing x with confirmation.
private struct SetRow: View {
    let name: String
    let countText: String
    let isActive: Bool
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onActivate) {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isActive ? .white : Theme.wine)
                        .frame(width: 34, height: 34)
                        .background(isActive ? Theme.wine : Color.white, in: Circle())
                        .overlay(
                            Circle().strokeBorder(Theme.wine, lineWidth: isActive ? 0 : 1.5)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(countText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.wine)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete set \(name)")
            .confirmationDialog(
                "Delete the set \"\(name)\"?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Add Calendar

/// Creates a new event calendar or task list in a chosen account, with a name,
/// a wine-family + standard color swatch row, and inline error handling.
struct AddCalendarSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var forReminders = false
    @State private var name = ""
    @State private var selectedSwatchID = "Wine"
    @State private var selectedAccountID: String?
    @State private var errorMessage: String?

    private struct Swatch: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }

    /// Wine family first, then six standard hues.
    private static let swatches: [Swatch] = [
        Swatch(name: "Wine", color: Theme.wine),
        Swatch(name: "Deep Wine", color: Theme.wineDeep),
        Swatch(name: "Rose", color: Theme.rose),
        Swatch(name: "Red", color: .red),
        Swatch(name: "Orange", color: .orange),
        Swatch(name: "Yellow", color: .yellow),
        Swatch(name: "Green", color: .green),
        Swatch(name: "Blue", color: .blue),
        Swatch(name: "Purple", color: .purple),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    kindPicker
                    nameSection
                    colorSection
                    accountSection
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.wine)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WineButton(title: "Create", systemImage: "plus") {
                        create()
                    }
                    .disabled(accounts.isEmpty)
                    .opacity(accounts.isEmpty ? 0.5 : 1)
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle(forReminders ? "New Task List" : "New Calendar")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .largeSheet()
    }

    // MARK: Sections

    private var kindPicker: some View {
        Picker("Type", selection: $forReminders) {
            Text("Event Calendar").tag(false)
            Text("Task List").tag(true)
        }
        .pickerStyle(.segmented)
        .tint(Theme.wine)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Name")
            TextField(forReminders ? "List name" : "Calendar name", text: $name)
                .font(.subheadline.weight(.semibold))
                .onSubmit(create)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Color")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(Self.swatches) { swatch in
                    swatchButton(swatch)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatchButton(_ swatch: Swatch) -> some View {
        let isSelected = swatch.id == selectedSwatchID
        return Button {
            selectedSwatchID = swatch.id
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .strokeBorder(Theme.wine, lineWidth: 1.5)
                        .frame(width: 40, height: 40)
                }
                Circle()
                    .fill(swatch.color)
                    .frame(width: 28, height: 28)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Account")
            if accounts.isEmpty {
                EmptyStateText(text: forReminders
                    ? "No account can hold a new list yet — connect Reminders access in Settings first."
                    : "No account can hold a new calendar yet — connect Calendars access in Settings first.")
            } else {
                HStack(spacing: 12) {
                    Text("Create in")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        ForEach(accounts) { account in
                            Button(menuLabel(for: account)) {
                                selectedAccountID = account.id
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedAccount?.title ?? "None")
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
                Text("Some accounts — including many Google setups — only accept new calendars made on their own website; if creation fails here, add it there and it syncs back.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Helpers

    private var accounts: [AccountSource] {
        store.accountSources(forReminders: forReminders)
    }

    /// Falls back to the first account when nothing (or a stale id) is selected.
    private var selectedAccount: AccountSource? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    private func menuLabel(for account: AccountSource) -> String {
        account.title.localizedCaseInsensitiveCompare(account.kind) == .orderedSame
            ? account.title
            : "\(account.title) · \(account.kind)"
    }

    private func create() {
        guard let account = selectedAccount else { return }
        let color = Self.swatches.first { $0.id == selectedSwatchID }?.color ?? Theme.wine
        if let failure = store.createCalendar(
            named: name, color: color, sourceID: account.id, forReminders: forReminders
        ) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}

// MARK: - Add Account

/// Explains how external accounts reach the app (through the system account
/// list) and offers curated public holiday feeds to subscribe to.
struct AddAccountSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    private struct HolidayFeed: Identifiable {
        let region: String
        let urlString: String
        var id: String { region }
    }

    /// Curated public holiday feeds; webcal:// hands them to the system's
    /// subscribe flow, so they arrive as a Subscribed account.
    private static let holidayFeeds: [HolidayFeed] = [
        HolidayFeed(region: "United States", urlString: "webcal://www.officeholidays.com/ics/usa"),
        HolidayFeed(region: "United Kingdom", urlString: "webcal://www.officeholidays.com/ics/united-kingdom"),
        HolidayFeed(region: "Canada", urlString: "webcal://www.officeholidays.com/ics/canada"),
        HolidayFeed(region: "Hong Kong", urlString: "webcal://www.officeholidays.com/ics/hong-kong"),
        HolidayFeed(region: "Japan", urlString: "webcal://www.officeholidays.com/ics/japan"),
        HolidayFeed(region: "Germany", urlString: "webcal://www.officeholidays.com/ics/germany"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accountsSection
                    holidaySection
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Add Account")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .largeSheet()
    }

    // MARK: Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Calendar Accounts")
            Text("Google, Exchange, and iCloud calendars all flow through the system's account list — add an account there and every calendar it holds appears in Mars Calendar automatically. Nothing extra to sign into here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WineButton(title: "Open Account Settings", systemImage: "person.crop.circle.badge.plus") {
                Platform.openAccountSettings()
            }
            Text("On iPhone and iPad that's Settings, under your Calendar accounts; on Mac it's Internet Accounts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Holiday feeds

    private var holidaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Holiday & Interesting Calendars")
            Text("Tap one to subscribe through the system — it arrives as its own Subscribed account and stays up to date on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.holidayFeeds) { feed in
                holidayRow(feed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func holidayRow(_ feed: HolidayFeed) -> some View {
        Button {
            if let url = URL(string: feed.urlString) {
                Platform.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(width: 34, height: 34)
                    .background(Color.white, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Theme.wine, lineWidth: 1.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(feed.region) Holidays")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Public holidays · officeholidays.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

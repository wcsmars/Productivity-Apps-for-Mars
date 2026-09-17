import SwiftUI

/// Detail sheet for a calendar event: read-only summary with an inline edit
/// mode (title, times, calendar, location, alert, notes) and delete.
struct EventDetailSheet: View {
    let event: EventItem

    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var confirmingDelete = false

    @State private var editTitle: String
    @State private var editIsAllDay: Bool
    @State private var editStart: Date
    @State private var editEnd: Date
    @State private var editCalendarID: String
    @State private var editLocation: String
    @State private var editAlertMinutes: Int?
    @State private var editNotes: String

    private let calendar = Calendar.current
    private let alertOptions: [Int?] = [nil, 0, 5, 10, 30, 60, 1440]

    init(event: EventItem) {
        self.event = event
        _editTitle = State(initialValue: event.title)
        _editIsAllDay = State(initialValue: event.isAllDay)
        _editStart = State(initialValue: event.start)
        _editEnd = State(initialValue: Self.displayEnd(for: event))
        _editCalendarID = State(initialValue: event.calendarID)
        _editLocation = State(initialValue: event.location ?? "")
        _editAlertMinutes = State(initialValue: event.alertMinutesBefore)
        _editNotes = State(initialValue: event.notes ?? "")
    }

    @StateObject private var templates = TemplateStore()
    @State private var savedAsTemplate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing {
                        editContent
                    } else {
                        viewContent
                    }
                    deleteButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color.white)
            .navigationTitle("Event")
            .inlineNavigationBarTitle()
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            resetEditState()
                            isEditing = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveEdits() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Edit") { isEditing = true }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .tint(Theme.wine)
        .safeAreaInset(edge: .top) { CalendarMutationErrorBanner() }
        .mediumOrLargeSheet()
    }

    // MARK: - View mode

    @ViewBuilder private var viewContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            HStack(spacing: 6) {
                CalendarDot(color: store.color(for: event.calendarID))
                Text(store.calendarSource(event.calendarID)?.title ?? "Calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let joinURL = ConferenceCall.joinURL(for: event) {
            JoinCallButton(url: joinURL)
        }
        DetailRow(icon: "calendar", title: dateTitle, subtitle: dateSubtitle)
        if let zoneID = event.timeZoneID {
            DetailRow(icon: "globe", title: zoneID.replacingOccurrences(of: "_", with: " "), subtitle: "Event time zone")
        }
        if event.hasRecurrence {
            DetailRow(icon: "repeat", title: event.recurrenceText ?? "Repeats")
        }
        if let minutes = event.alertMinutesBefore {
            DetailRow(icon: "bell.fill", title: alertLabel(minutes))
        }
        if let location = event.location {
            DetailRow(icon: "mappin.and.ellipse", title: location)
            LocationMapCard(location: location)
        }
        if !event.attendees.isEmpty {
            AttendeeRows(attendees: event.attendees)
        }
        if let notes = event.notes {
            Text(notes)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        shareAndTemplateRow
    }

    /// Export the event as .ics and reuse it as a template.
    private var shareAndTemplateRow: some View {
        HStack(spacing: 10) {
            if let file = ICSExporter.icsFile(
                for: event,
                calendarName: store.calendarSource(event.calendarID)?.title ?? "Mars Calendar"
            ) {
                ShareLink(item: file) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.wine)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            Button {
                templates.add(TemplateStore.template(named: event.title, from: event))
                savedAsTemplate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: savedAsTemplate ? "checkmark" : "square.on.square")
                    Text(savedAsTemplate ? "Template Saved" : "Save as Template")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.wine)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(savedAsTemplate)
        }
    }

    /// Last day the event visibly covers (all-day ends are exclusive).
    private static func displayEnd(for event: EventItem) -> Date {
        guard event.isAllDay else { return event.end }
        let candidate = Calendar.current.date(byAdding: .day, value: -1, to: event.end) ?? event.end
        return max(candidate, event.start)
    }

    private var isMultiDay: Bool {
        !calendar.isDate(event.start, inSameDayAs: Self.displayEnd(for: event))
    }

    private var dateTitle: String {
        isMultiDay
            ? "\(Format.shortDate(event.start)) – \(Format.shortDate(Self.displayEnd(for: event)))"
            : Format.dayHeader(event.start)
    }

    private var dateSubtitle: String {
        event.isAllDay ? "All day" : Format.timeRange(event.start, event.end)
    }

    private func alertLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "None" }
        switch minutes {
        case 0: return "At time of event"
        case 60: return "1 hour before"
        case 1440: return "1 day before"
        default: return "\(minutes) min before"
        }
    }

    // MARK: - Edit mode

    @ViewBuilder private var editContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $editTitle)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            Toggle("All-day", isOn: $editIsAllDay)
                .font(.subheadline.weight(.semibold))
                .tint(Theme.wine)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            DatePicker(
                "Starts",
                selection: $editStart,
                displayedComponents: editIsAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .font(.subheadline.weight(.semibold))
            .datePickerStyle(.compact)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            DatePicker(
                "Ends",
                selection: $editEnd,
                in: editStart...,
                displayedComponents: editIsAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .font(.subheadline.weight(.semibold))
            .datePickerStyle(.compact)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            if store.calendarSource(event.calendarID)?.allowsModifications == true {
                calendarMenu
            }

            TextField("Location", text: $editLocation)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            alertMenu

            TextField("Notes", text: $editNotes, axis: .vertical)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3...6)
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))

            if event.hasRecurrence {
                Text("Edits apply to this occurrence only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: editStart) { oldValue, newValue in
            if editEnd < newValue {
                let duration = max(editEnd.timeIntervalSince(oldValue), 0)
                editEnd = newValue.addingTimeInterval(duration)
            }
        }
    }

    private var calendarMenu: some View {
        Menu {
            ForEach(store.writableCalendars) { source in
                Button {
                    editCalendarID = source.id
                } label: {
                    if source.id == editCalendarID {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                CalendarDot(color: store.color(for: editCalendarID))
                Text(store.calendarSource(editCalendarID)?.title ?? "Calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var alertMenu: some View {
        Menu {
            ForEach(alertOptions, id: \.self) { option in
                Button {
                    editAlertMinutes = option
                } label: {
                    if option == editAlertMinutes {
                        Label(alertLabel(option), systemImage: "checkmark")
                    } else {
                        Text(alertLabel(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.wine)
                Text("Alert: \(alertLabel(editAlertMinutes))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resetEditState() {
        editTitle = event.title
        editIsAllDay = event.isAllDay
        editStart = event.start
        editEnd = Self.displayEnd(for: event)
        editCalendarID = event.calendarID
        editLocation = event.location ?? ""
        editAlertMinutes = event.alertMinutesBefore
        editNotes = event.notes ?? ""
    }

    private func saveEdits() {
        var updated = event
        let title = editTitle.trimmingCharacters(in: .whitespaces)
        updated.title = title.isEmpty ? event.title : title
        updated.isAllDay = editIsAllDay
        if editIsAllDay {
            let firstDay = calendar.startOfDay(for: editStart)
            let lastDay = max(calendar.startOfDay(for: editEnd), firstDay)
            updated.start = firstDay
            updated.end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        } else {
            updated.start = editStart
            updated.end = max(editEnd, editStart)
        }
        updated.calendarID = editCalendarID
        let location = editLocation.trimmingCharacters(in: .whitespaces)
        updated.location = location.isEmpty ? nil : location
        updated.alertMinutesBefore = editAlertMinutes
        let notes = editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = notes.isEmpty ? nil : notes
        if store.save(event: updated) { dismiss() }
    }

    // MARK: - Delete

    private var deleteButton: some View {
        WineOutlineButton(title: "Delete Event", systemImage: "trash") {
            confirmingDelete = true
        }
        .confirmationDialog(
            event.hasRecurrence ? "This is a repeating event." : "Delete this event?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            if event.hasRecurrence {
                Button("Delete This Event", role: .destructive) {
                    if store.delete(event: event, futureOccurrences: false) { dismiss() }
                }
                Button("Delete All Future Events", role: .destructive) {
                    if store.delete(event: event, futureOccurrences: true) { dismiss() }
                }
            } else {
                Button("Delete", role: .destructive) {
                    if store.delete(event: event) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Row

/// Blush info row with a filled wine 34pt circle icon (suite row pattern).
private struct DetailRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.wine, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

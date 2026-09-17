import SwiftUI

/// Fantastical-style natural-language quick add: a single text field parsed on
/// every keystroke into a live preview card, with structured override rows
/// below. Overrides are stored separately and re-applied on top of each fresh
/// parse so typing keeps working after a manual adjustment.
struct QuickAddSheet: View {
    @EnvironmentObject private var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    private let prefillDay: Date?
    private let prefillKind: ItemDraft.Kind

    @State private var text = ""
    @State private var draft = ItemDraft()
    @State private var kind: ItemDraft.Kind
    @State private var userOverrodeKind = false
    /// Date override. Seeded from `prefillDay`; a seeded (untouched) value
    /// yields to a date typed in the field, a user-picked one wins outright.
    @State private var dateOverride: Date?
    @State private var userTouchedDate = false
    /// nil = follow the parse; true/false = user forced time on/off.
    @State private var timeOverride: Bool?
    @State private var timeValue: Date
    @State private var durationOverride: Int?
    @State private var calendarOverride: String?
    @State private var alertOverride: AlertChoice?
    @State private var saveError: String?
    @State private var selectedTemplate: EventTemplate?
    @StateObject private var templates = TemplateStore()
    @FocusState private var fieldFocused: Bool

    private enum AlertChoice: Equatable {
        case off
        case minutes(Int)
    }

    init(prefillDay: Date? = nil, prefillKind: ItemDraft.Kind = .event) {
        self.prefillDay = prefillDay
        self.prefillKind = prefillKind
        _kind = State(initialValue: prefillKind)
        _dateOverride = State(initialValue: prefillDay)
        let day = prefillDay ?? .now
        _timeValue = State(initialValue: Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: day
        ) ?? day)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputField
                    if !templates.templates.isEmpty {
                        templateRow
                    }
                    kindPicker
                    previewCard
                    ForEach(draft.validationErrors, id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.wine)
                    }
                    adjustSection
                    if let saveError {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(Theme.wine)
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("New Item")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.wine)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        Text("Add").bold()
                    }
                    .tint(Theme.wine)
                    .disabled(trimmedText.isEmpty || !draft.validationErrors.isEmpty)
                }
            }
        }
        .largeSheet()
        .onAppear {
            #if DEBUG
            // Apply the quick-add demo launch arguments.
            if text.isEmpty, CommandLine.arguments.contains("-demoQuickAddText") {
                text = "Lunch with Alex tomorrow 1pm at Cafe Rio alert 30 minutes /work"
            }
            #endif
            reparse()
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                fieldFocused = true
            }
        }
        .onChange(of: text) { reparse() }
    }

    // MARK: - Input

    private var inputField: some View {
        TextField("Try 'Lunch with Alex tomorrow 1pm at Cafe Rio'", text: $text)
            .font(.subheadline.weight(.semibold))
            .submitLabel(.done)
            .onSubmit(save)
            .focused($fieldFocused)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private var kindPicker: some View {
        Picker("Type", selection: kindBinding) {
            Text("Event").tag(ItemDraft.Kind.event)
            Text("Task").tag(ItemDraft.Kind.task)
        }
        .pickerStyle(.segmented)
        .tint(Theme.wine)
    }

    private var kindBinding: Binding<ItemDraft.Kind> {
        Binding(
            get: { kind },
            set: { newValue in
                guard newValue != kind else { return }
                kind = newValue
                userOverrodeKind = true
                calendarOverride = nil
                reparse()
            }
        )
    }

    // MARK: - Preview card

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.title.isEmpty ? (draft.kind == .task ? "New Task" : "New Event") : draft.title)
                .font(.headline)
                .foregroundStyle(draft.title.isEmpty ? Color.secondary : Theme.wineDeep)
                .lineLimit(2)
            FlowLayout(spacing: 8) {
                chips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 18))
        .animation(.snappy, value: draft)
    }

    @ViewBuilder private var chips: some View {
        if let dateText = dateChipText {
            ParseChip(systemImage: "calendar", text: dateText)
                .transition(.scale.combined(with: .opacity))
        }
        if let timeText = timeChipText {
            ParseChip(systemImage: "clock", text: timeText)
                .transition(.scale.combined(with: .opacity))
        }
        if let minutes = draft.durationMinutes {
            ParseChip(systemImage: "timer", text: Format.duration(TimeInterval(minutes * 60)))
                .transition(.scale.combined(with: .opacity))
        }
        if let recurrence = draft.recurrence {
            ParseChip(systemImage: "repeat", text: recurrence.text)
                .transition(.scale.combined(with: .opacity))
        }
        if let alertMinutes = draft.alertMinutesBefore {
            ParseChip(systemImage: "bell.fill", text: alertText(alertMinutes))
                .transition(.scale.combined(with: .opacity))
        }
        if let location = draft.location {
            ParseChip(systemImage: "mappin.and.ellipse", text: location)
                .transition(.scale.combined(with: .opacity))
        }
        if draft.kind == .task, draft.priority > 0 {
            ParseChip(
                systemImage: "exclamationmark.circle.fill",
                text: String(repeating: "!", count: min(draft.priority, 3))
            )
            .transition(.scale.combined(with: .opacity))
        }
        if let calendar = resolvedCalendar {
            ParseChip(systemImage: "circle.fill", text: calendar.title)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var dateChipText: String? {
        guard let start = draft.start else { return nil }
        if draft.isAllDay, let endDay = draft.endDay {
            if Calendar.current.isDate(start, equalTo: endDay, toGranularity: .month) {
                return "\(Format.shortDate(start)) – \(endDay.formatted(.dateTime.day()))"
            }
            return "\(Format.shortDate(start)) – \(Format.shortDate(endDay))"
        }
        return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var timeChipText: String? {
        if draft.isAllDay { return "All day" }
        guard draft.hasTime, let start = draft.start else { return nil }
        if let end = draft.end { return Format.timeRange(start, end) }
        return Format.time(start)
    }

    /// The calendar or list the item will land in, for the chip and menu.
    private var resolvedCalendar: CalendarSource? {
        if let id = draft.calendarID, let source = store.calendarSource(id) { return source }
        return draft.kind == .task ? store.defaultTaskList : store.defaultCalendar
    }

    // MARK: - Adjust section

    private var adjustSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Adjust")
            adjustRow("Date") {
                DatePicker("", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.wine)
                    .accessibilityLabel("Date")
            }
            adjustRow("Time") {
                if draft.hasTime {
                    DatePicker("", selection: timePickerBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(Theme.wine)
                        .accessibilityLabel("Time")
                }
                Toggle("", isOn: timeToggleBinding)
                    .labelsHidden()
                    .fixedSize()
                    .tint(Theme.wine)
                    .accessibilityLabel("Include time")
            }
            if kind == .event {
                adjustRow("Duration") { durationMenu }
            }
            adjustRow(kind == .task ? "List" : "Calendar") { calendarMenu }
            adjustRow("Alert") { alertMenu }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adjustRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }

    private var durationMenu: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button(Format.duration(TimeInterval(minutes * 60))) {
                    durationOverride = minutes
                    reparse()
                }
            }
        } label: {
            menuLabel(Format.duration(TimeInterval(
                (draft.durationMinutes ?? store.defaultDurationMinutes) * 60
            )))
        }
    }

    private var calendarMenu: some View {
        let options = kind == .task ? store.taskLists : store.writableCalendars
        return Menu {
            ForEach(options) { source in
                Button {
                    calendarOverride = source.id
                    reparse()
                } label: {
                    if source.id == resolvedCalendar?.id {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
        } label: {
            menuLabel(resolvedCalendar?.title ?? "None", dotColor: resolvedCalendar?.color)
        }
    }

    private var alertMenu: some View {
        Menu {
            Button("None") { alertOverride = .off; reparse() }
            Button("At time") { alertOverride = .minutes(0); reparse() }
            Button("5 min before") { alertOverride = .minutes(5); reparse() }
            Button("10 min before") { alertOverride = .minutes(10); reparse() }
            Button("30 min before") { alertOverride = .minutes(30); reparse() }
            Button("1 hour before") { alertOverride = .minutes(60); reparse() }
            Button("1 day before") { alertOverride = .minutes(1440); reparse() }
        } label: {
            menuLabel(draft.alertMinutesBefore.map(alertText) ?? "None")
        }
    }

    private func menuLabel(_ text: String, dotColor: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let dotColor {
                CalendarDot(color: dotColor)
            }
            Text(text)
                .font(.subheadline.weight(.bold))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.wine)
    }

    // MARK: - Override bindings

    private var dateBinding: Binding<Date> {
        Binding(
            // The draft already has any applied override folded in, so it is the
            // effective value; the raw override is only a fallback before parsing.
            get: { draft.start ?? dateOverride ?? prefillDay ?? .now },
            set: { newValue in
                dateOverride = newValue
                userTouchedDate = true
                reparse()
            }
        )
    }

    private var timeToggleBinding: Binding<Bool> {
        Binding(
            get: { timeOverride ?? draft.hasTime },
            set: { isOn in
                if isOn, timeOverride != true, draft.hasTime, let start = draft.start {
                    timeValue = start
                }
                timeOverride = isOn
                reparse()
            }
        )
    }

    private var timePickerBinding: Binding<Date> {
        Binding(
            get: {
                if timeOverride == true { return timeValue }
                if draft.hasTime, let start = draft.start { return start }
                return timeValue
            },
            set: { newValue in
                timeValue = newValue
                timeOverride = true
                reparse()
            }
        )
    }

    // MARK: - Templates

    /// Saved templates keep their title literal; appended text can supply a date
    /// or time, and the structured controls can adjust the saved defaults.
    private var templateRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(templates.templates) { template in
                    Button {
                        apply(template)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 11, weight: .bold))
                            Text(template.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.wineDeep)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.blush, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Template", role: .destructive) {
                            templates.delete(template)
                        }
                    }
                }
            }
        }
    }

    private func apply(_ template: EventTemplate) {
        selectedTemplate = template
        text = template.title
        timeOverride = nil
        durationOverride = nil
        calendarOverride = nil
        alertOverride = nil
        reparse()
    }

    // MARK: - Parse pipeline

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reparse() {
        saveError = nil
        let sources = store.calendars + store.taskLists
        var parsed = selectedTemplate?.draft(from: text, calendars: sources, defaultTime: timeValue)
            ?? QuickParse.parse(text, calendars: sources)
        if userOverrodeKind {
            parsed.kind = kind
        } else {
            // The parser flips to .task on todo/reminder markers or trailing "!";
            // a task prefill keeps the sheet in task mode until the user says otherwise.
            let autoKind: ItemDraft.Kind = (parsed.kind == .task || prefillKind == .task) ? .task : .event
            kind = autoKind
            parsed.kind = autoKind
        }
        applyOverrides(to: &parsed)
        draft = parsed
    }

    private func applyOverrides(to parsed: inout ItemDraft) {
        let calendar = Calendar.current

        if let calendarOverride { parsed.calendarID = calendarOverride }
        if let durationOverride {
            parsed.durationMinutes = durationOverride
            parsed.end = nil
        }
        if let alertOverride {
            switch alertOverride {
            case .off: parsed.alertMinutesBefore = nil
            case .minutes(let minutes): parsed.alertMinutesBefore = minutes
            }
        }

        // A seeded (prefill) date override yields to an explicitly TYPED date; a
        // user-picked one wins. A bare time ("Dentist 3pm") is not a typed date —
        // it must land on the day the user was viewing, not default to today.
        let overrideDay: Date? = {
            guard let dateOverride else { return nil }
            return (userTouchedDate || !parsed.hasExplicitDate) ? dateOverride : nil
        }()
        var day = (overrideDay ?? parsed.start).map { calendar.startOfDay(for: $0) }
        let wantsTime = timeOverride ?? parsed.hasTime

        if wantsTime {
            let source: Date = if timeOverride == true {
                timeValue
            } else if parsed.hasTime, let start = parsed.start {
                start
            } else {
                timeValue
            }
            if day == nil { day = calendar.startOfDay(for: prefillDay ?? .now) }
            let parts = calendar.dateComponents([.hour, .minute], from: source)
            let start = calendar.date(
                bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day!
            ) ?? day!
            if timeOverride == true {
                parsed.end = nil                       // forced time: duration wins
            } else if parsed.hasTime, let oldStart = parsed.start, let oldEnd = parsed.end {
                parsed.end = start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
            }
            parsed.start = start
            parsed.hasTime = true
            parsed.isAllDay = false
            parsed.endDay = nil
        } else {
            if let day {
                parsed.start = day
                if let endDay = parsed.endDay, endDay <= day { parsed.endDay = nil }
                if parsed.kind == .event { parsed.isAllDay = true }
            }
            parsed.hasTime = false
            parsed.end = nil
        }
    }

    private func alertText(_ minutes: Int) -> String {
        switch minutes {
        case 0: "At time"
        case 1440: "1 day before"
        case let m where m >= 60 && m % 60 == 0: m == 60 ? "1 hour before" : "\(m / 60) hours before"
        default: "\(minutes) min before"
        }
    }

    // MARK: - Save

    private func save() {
        guard !trimmedText.isEmpty, draft.validationErrors.isEmpty else { return }
        var final = draft
        if final.kind == .event, final.start == nil {
            final.start = Calendar.current.startOfDay(for: prefillDay ?? .now)
            final.isAllDay = true
            final.hasTime = false
        }
        if store.createItem(from: final) {
            dismiss()
        } else {
            saveError = "Couldn't save — check calendar access in Settings and try again."
        }
    }
}

// MARK: - Flow layout

/// Left-aligned wrapping layout for the preview chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width
            usedWidth = max(usedWidth, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        let height = subviews.isEmpty ? 0 : y + rowHeight
        return CGSize(width: maxWidth == .infinity ? usedWidth : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

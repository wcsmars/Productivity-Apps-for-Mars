import SwiftUI

struct AddEntrySheet: View {
    let category: TrackerCategory
    let day: Date

    @EnvironmentObject private var store: EntryStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ValueKind
    @State private var hours = 0
    @State private var minutes = 30
    @State private var numberText = ""
    @State private var didSave = false
    @FocusState private var numberFieldFocused: Bool

    init(category: TrackerCategory, day: Date) {
        self.category = category
        self.day = day
        _kind = State(initialValue: category.defaultKind)
    }

    private var numberValue: Double? {
        Double(numberText.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        switch kind {
        case .duration: hours > 0 || minutes > 0
        case .number: (numberValue ?? 0) > 0 && (numberValue ?? 0) <= 999_999
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                header
                if category.supportsDuration {
                    Picker("Log as", selection: $kind) {
                        Text("Duration").tag(ValueKind.duration)
                        Text("Count").tag(ValueKind.number)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == .duration {
                    durationPickers
                } else {
                    numberField
                }
                Spacer()
                saveButton
            }
            .padding()
            .navigationTitle("Log \(category.title)")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .mediumSheet()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(category.isOutlined ? Theme.wine : .white)
                .frame(width: 40, height: 40)
                .background(
                    category.isOutlined ? Color.white : category.color,
                    in: Circle()
                )
                .overlay(
                    Circle().strokeBorder(Theme.wine, lineWidth: category.isOutlined ? 1.5 : 0)
                )
            Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var durationPickers: some View {
        #if os(macOS)
        // No wheel picker on macOS — menu pickers instead.
        HStack(spacing: 20) {
            Picker("Hours", selection: $hours) {
                ForEach(0..<13, id: \.self) { value in
                    Text("\(value) h").tag(value)
                }
            }
            Picker("Minutes", selection: $minutes) {
                ForEach(0..<60, id: \.self) { value in
                    Text("\(value) m").tag(value)
                }
            }
        }
        .pickerStyle(.menu)
        .padding(.vertical, 32)
        #else
        HStack(spacing: 0) {
            Picker("Hours", selection: $hours) {
                ForEach(0..<13, id: \.self) { value in
                    Text("\(value) h").tag(value)
                }
            }
            .pickerStyle(.wheel)
            Picker("Minutes", selection: $minutes) {
                ForEach(0..<60, id: \.self) { value in
                    Text("\(value) m").tag(value)
                }
            }
            .pickerStyle(.wheel)
        }
        .frame(height: 150)
        #endif
    }

    private var numberField: some View {
        HStack {
            TextField(category == .weight ? "72.5" : "0", text: $numberText)
                .decimalPadKeyboard()
                .focused($numberFieldFocused)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            if let unit = category.numberUnit {
                Text(unit)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { numberFieldFocused = true }
    }

    private var saveButton: some View {
        Button {
            // A second tap can land before the sheet finishes dismissing.
            guard !didSave else { return }
            didSave = true
            let amount: Double = switch kind {
            case .duration: Double(hours * 3600 + minutes * 60)
            case .number: numberValue ?? 0
            }
            store.add(category: category, kind: kind, amount: amount, on: day)
            dismiss()
        } label: {
            Text("Save")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    canSave ? Theme.wine : Theme.wine.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .disabled(!canSave)
    }
}

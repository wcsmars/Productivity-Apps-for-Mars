import SwiftUI

/// Visible in both the main window and detail sheets, so failed operations
/// leave a recoverable explanation without dismissing an unsaved edit.
struct CalendarMutationErrorBanner: View {
    @EnvironmentObject private var store: CalendarStore

    var body: some View {
        if let message = store.mutationError {
            HStack(alignment: .top, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.mutationError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .foregroundStyle(Theme.wineDeep)
            .padding()
            .background(Theme.blush)
        }
    }
}

// MARK: - Text atoms

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Theme.wineDeep)
    }
}

struct EmptyStateText: View {
    let text: String

    init(_ text: String) { self.text = text }
    init(text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }
}

/// Day-group header for event lists: bold weekday + date, wine when today.
struct DayHeaderView: View {
    let day: Date
    var isToday: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.dayHeader(day))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isToday ? Theme.wine : Theme.wineDeep)
            if let relative = Format.relativeDay(day) {
                Text(relative)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isToday ? Theme.wine : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}

// MARK: - Rows

/// Timed-event row: fixed time column, colored calendar bar, then title + detail.
struct EventRow: View {
    let event: EventItem
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.time(event.start))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(Format.time(event.end))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 64, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if event.hasRecurrence {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var detailLine: String? {
        if let location = event.location, !location.isEmpty { return location }
        return nil
    }
}

/// All-day event: full-width filled bar in the calendar's color.
struct AllDayRow: View {
    let event: EventItem
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(event.title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if event.hasRecurrence {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.8)
            }
            Text("all day")
                .font(.caption2.weight(.semibold))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(color, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

/// Task row with a tappable completion circle in the list's color.
struct TaskRow: View {
    let task: TaskItem
    let color: Color
    var showsDate: Bool = false
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                    if task.isCompleted {
                        Circle()
                            .fill(color)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(1)
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isOverdue ? Theme.wine : .secondary)
                }
            }
            Spacer(minLength: 0)
            if task.priority > 0 {
                Text(task.priorityMarks)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.wine)
            }
            if task.hasRecurrence {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var isOverdue: Bool {
        guard let due = task.due, !task.isCompleted else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    private var detailLine: String? {
        guard let due = task.due else { return nil }
        var parts: [String] = []
        if showsDate || isOverdue {
            parts.append(Format.relativeDay(due) ?? Format.shortDate(due))
        }
        if task.hasDueTime { parts.append(Format.time(due)) }
        if isOverdue { parts.append("overdue") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Buttons & chips

/// Filled wine primary button, full width.
struct WineButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.wine, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Outlined secondary button, full width.
struct WineOutlineButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(Theme.wine)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.wine, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Filled wine capsule chip used by the quick-add live preview.
struct ParseChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.wine, in: Capsule())
    }
}

/// Small color swatch for calendar pickers and legends.
struct CalendarDot: View {
    let color: Color
    var filled: Bool = true

    var body: some View {
        if filled {
            Circle().fill(color).frame(width: 8, height: 8)
        } else {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }
}

// MARK: - Access prompt

/// Shown when calendar/reminder access is missing: filled card + action.
struct AccessPromptCard: View {
    let icon: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.wine)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.wineDeep)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WineButton(title: buttonTitle, action: action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 18))
    }
}

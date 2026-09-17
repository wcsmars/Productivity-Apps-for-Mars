import SwiftUI

enum TrackerCategory: String, Codable, CaseIterable, Identifiable {
    case study
    case gym
    case cardio
    case weight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .study: "Study"
        case .gym: "Gym"
        case .cardio: "Cardio"
        case .weight: "Weight"
        }
    }

    var icon: String {
        switch self {
        case .study: "book.fill"
        case .gym: "dumbbell.fill"
        case .cardio: "figure.run"
        case .weight: "scalemass.fill"
        }
    }

    var color: Color {
        switch self {
        case .study: Theme.wine
        case .gym: Theme.wineDeep
        case .cardio: Theme.rose
        case .weight: Theme.wine
        }
    }

    /// Weight is drawn as a wine outline on white; activities are solid fills.
    var isOutlined: Bool { self == .weight }

    /// Weight is always a plain number; everything else can also be a duration.
    var supportsDuration: Bool { self != .weight }

    var defaultKind: ValueKind { supportsDuration ? .duration : .number }

    var numberUnit: String? {
        guard self == .weight else { return nil }
        return Locale.current.measurementSystem == .metric ? "kg" : "lb"
    }
}

enum ValueKind: String, Codable {
    case number
    case duration
}

/// An optional per-category target: a daily duration/count for activities,
/// or a target weight for the weight category.
struct Goal: Codable, Equatable {
    var kind: ValueKind
    /// Seconds when `kind == .duration`, otherwise the raw number.
    var amount: Double

    var formatted: String {
        switch kind {
        case .duration: Format.duration(amount)
        case .number: Format.number(amount)
        }
    }
}

struct Entry: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var category: TrackerCategory
    var kind: ValueKind
    /// Seconds when `kind == .duration`, otherwise the raw number.
    var amount: Double

    init(id: UUID = UUID(), date: Date = .now, category: TrackerCategory, kind: ValueKind, amount: Double) {
        self.id = id
        self.date = date
        self.category = category
        self.kind = kind
        self.amount = amount
    }

    var formattedAmount: String {
        switch kind {
        case .duration: Format.duration(amount)
        case .number: Format.number(amount, unit: category.numberUnit)
        }
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let totalMinutes = (seconds / 60).rounded()
        let hours = (totalMinutes / 60).rounded(.down)
        let minutes = totalMinutes.truncatingRemainder(dividingBy: 60)
        if hours > 0 && minutes > 0 { return "\(number(hours))h \(number(minutes))m" }
        if hours > 0 { return "\(number(hours))h" }
        return "\(number(minutes))m"
    }

    static func number(_ value: Double, unit: String? = nil) -> String {
        // Formatter, not String(Int(_:)) — the latter traps on values beyond Int.max.
        let text = value.formatted(.number.precision(.fractionLength(0...1)))
        if let unit, !unit.isEmpty { return "\(text) \(unit)" }
        return text
    }

    /// Compact duration for calendar cells: "45m", "1.5h", "2h".
    static func shortDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let totalMinutes = (seconds / 60).rounded()
        if totalMinutes < 60 { return "\(number(totalMinutes))m" }
        // Round to tenths first so 61 minutes prints "1h", not "1.0h".
        let tenths = (totalMinutes / 60 * 10).rounded()
        return "\(number(tenths / 10))h"
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

/// Records a deleted entry id so deletions survive the union-based sync merge.
struct Tombstone: Codable, Equatable {
    let id: UUID
    let deletedAt: Date?
}

/// JSON coding shared by local persistence and the sync API. The decoder
/// accepts both plain and fractional-second ISO 8601 dates (the web app
/// historically wrote fractional seconds).
enum MarsJSON {
    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = isoPlain.date(from: text) ?? isoFractional.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized date: \(text)"
            ))
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Goal conflict resolution needs milliseconds: dropping them can make a
        // later native edit sort before a web edit made in the same second.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

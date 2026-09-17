import CoreLocation
import MapKit
import SwiftUI

// MARK: - Conference calls

/// Detects video-call links (Zoom, Google Meet, Teams, Webex, FaceTime) in an
/// event's URL, location, or notes so the detail sheet can offer one-tap join.
enum ConferenceCall {
    /// Regexes for the services we recognize, in priority order.
    private static let patterns: [String] = [
        #"(?:https?://)?(?:[A-Za-z0-9.-]+\.)?zoom\.us/(?:j|my)/[^\s<>"',]+"#,
        #"(?:https?://)?meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[^\s<>"',]*)?"#,
        #"(?:https?://)?teams\.microsoft\.com/l/meetup-join/[^\s<>"',]+"#,
        #"(?:https?://)?(?:[A-Za-z0-9.-]+\.)?webex\.com/(?:meet|join)/[^\s<>"',]+"#,
        #"facetime(?:-audio)?://[^\s<>"',]+"#,
        #"(?:https?://)?facetime\.apple\.com/join[^\s<>"',]*"#,
    ]

    /// The first joinable conference link found in the event's URL, location,
    /// or notes — nil when the event has no recognizable call link.
    static func joinURL(for event: EventItem) -> URL? {
        for text in [event.url?.absoluteString, event.location, event.notes] {
            guard let text else { continue }
            if let url = firstMatch(in: text) { return url }
        }
        return nil
    }

    private static func firstMatch(in text: String) -> URL? {
        for pattern in patterns {
            guard let range = text.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            var raw = String(text[range])
            // Trailing prose punctuation isn't part of the link.
            while let last = raw.last, ".,;:)".contains(last) { raw.removeLast() }
            let lower = raw.lowercased()
            if !lower.hasPrefix("http") && !lower.hasPrefix("facetime") {
                raw = "https://" + raw
            }
            if let url = URL(string: raw) { return url }
        }
        return nil
    }
}

/// Primary "Join Call" action for events with a detected conference link.
struct JoinCallButton: View {
    let url: URL

    init(url: URL) { self.url = url }

    var body: some View {
        WineButton(title: "Join Call", systemImage: "video.fill") {
            Platform.open(url)
        }
    }
}

// MARK: - Location map

/// Geocodes an event's location once and, on success, shows a small map
/// snippet with a wine marker plus a Directions button. Renders nothing while
/// unresolved or on failure — the plain location row already covers that.
struct LocationMapCard: View {
    let location: String

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var attemptedLocation: String?

    init(location: String) { self.location = location }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker(location, coordinate: coordinate)
                        .tint(Theme.wine)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
                .accessibilityLabel("Map of \(location)")
                WineOutlineButton(
                    title: "Directions",
                    systemImage: "arrow.triangle.turn.up.right.diamond"
                ) {
                    if let url = directionsURL { Platform.open(url) }
                }
            }
        }
        .task(id: location) { await geocodeIfNeeded() }
    }

    private var directionsURL: URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = location.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "http://maps.apple.com/?daddr=\(encoded)")
    }

    private func geocodeIfNeeded() async {
        guard attemptedLocation != location else { return }
        attemptedLocation = location
        let placemarks = try? await CLGeocoder().geocodeAddressString(location)
        coordinate = placemarks?.first?.location?.coordinate
    }
}

// MARK: - Attendees

/// "Invitees" section for the event detail sheet: one blush row per attendee,
/// organizer shown with the filled circle (suite filled/outlined motif).
struct AttendeeRows: View {
    let attendees: [Attendee]

    init(attendees: [Attendee]) { self.attendees = attendees }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Invitees")
            ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                row(for: attendee)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for attendee: Attendee) -> some View {
        HStack(spacing: 12) {
            Image(systemName: attendee.isOrganizer ? "person.fill" : "person")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(attendee.isOrganizer ? Color.white : Theme.wine)
                .frame(width: 34, height: 34)
                .background(attendee.isOrganizer ? Theme.wine : Color.white, in: Circle())
                .overlay(
                    Circle().strokeBorder(Theme.wine, lineWidth: attendee.isOrganizer ? 0 : 1.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(attendee.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if attendee.isOrganizer {
                    Text("Organizer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(attendee.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(attendee.status == .accepted ? Theme.wine : .secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.blush, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - ICS export

/// Writes a single event as an RFC 5545 .ics file in a temp directory so it
/// can be shared. Returns nil if writing fails.
enum ICSExporter {
    static func icsFile(for event: EventItem, calendarName: String) -> URL? {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Mars Calendar//Mars Calendar//EN",
            "CALSCALE:GREGORIAN",
            "X-WR-CALNAME:\(escape(calendarName))",
            "BEGIN:VEVENT",
            "UID:\(escape(event.eventID))",
            "DTSTAMP:\(utcStamp(.now))",
        ]
        if event.isAllDay {
            // The app's all-day ends are already EXCLUSIVE midnights, which is
            // exactly RFC 5545's convention for DTEND;VALUE=DATE — write both
            // boundaries as-is, formatted in the local calendar's time zone.
            lines.append("DTSTART;VALUE=DATE:\(dateStamp(event.start))")
            lines.append("DTEND;VALUE=DATE:\(dateStamp(event.end))")
        } else {
            lines.append("DTSTART:\(utcStamp(event.start))")
            lines.append("DTEND:\(utcStamp(event.end))")
        }
        lines.append("SUMMARY:\(escape(event.title))")
        if let location = event.location {
            lines.append("LOCATION:\(escape(location))")
        }
        if let notes = event.notes {
            lines.append("DESCRIPTION:\(escape(notes))")
        }
        if let url = event.url {
            lines.append("URL:\(url.absoluteString)")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        let body = lines.flatMap(fold).joined(separator: "\r\n") + "\r\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory
            .appendingPathComponent(fileName(for: event.title))
            .appendingPathExtension("ics")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    /// RFC 5545 TEXT escaping: backslash first, then structural characters,
    /// then newlines as literal "\n".
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// RFC 5545 line folding: continuation lines start with a single space.
    private static func fold(_ line: String) -> [String] {
        guard line.count > 74 else { return [line] }
        var pieces: [String] = []
        var remainder = Substring(line)
        var isFirst = true
        while !remainder.isEmpty {
            let chunk = remainder.prefix(isFirst ? 74 : 73)
            pieces.append(isFirst ? String(chunk) : " " + chunk)
            remainder = remainder.dropFirst(chunk.count)
            isFirst = false
        }
        return pieces
    }

    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// All-day boundaries are local midnights — format them in the local zone.
    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func fileName(for title: String) -> String {
        let cleaned = String(title.map { character in
            character.isLetter || character.isNumber
                || character == " " || character == "-" || character == "_"
                ? character
                : "-"
        }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Event" : cleaned
    }
}

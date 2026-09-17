import Foundation
import UserNotifications

protocol SessionNotifications {
    func scheduleEnd(for session: ActiveSession)
    func cancelEnd(id: UUID)
}

struct LocalSessionNotifications: SessionNotifications {
    func scheduleEnd(for session: ActiveSession) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let interval = session.endsAt.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Session complete"
        content.body = "You stayed focused for \(Format.duration(session.plannedDuration)). Nice work."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelEnd(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}

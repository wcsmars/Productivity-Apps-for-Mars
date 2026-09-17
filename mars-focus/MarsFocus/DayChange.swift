import SwiftUI

private struct DayChangeAware: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                action()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { action() }
            }
    }
}

extension View {
    /// Runs `action` when the calendar day rolls over or the app returns to the foreground,
    /// so date-dependent views never keep showing yesterday as "today".
    func onDayChange(perform action: @escaping () -> Void) -> some View {
        modifier(DayChangeAware(action: action))
    }
}

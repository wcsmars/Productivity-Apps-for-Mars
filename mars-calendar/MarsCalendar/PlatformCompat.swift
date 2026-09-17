import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Shims for APIs that exist on iOS/iPadOS but not on native macOS, so the
// shared views stay free of #if noise (same pattern as Mars Momentum).
extension View {
    /// Medium sheet the user can pull to full height; sized window sheet on macOS.
    @ViewBuilder
    func mediumOrLargeSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 460, minHeight: 540)
        #else
        presentationDetents([.medium, .large])
        #endif
    }

    /// Full-height sheet; sized window sheet on macOS.
    @ViewBuilder
    func largeSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 520, minHeight: 640)
        #else
        presentationDetents([.large])
        #endif
    }

    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Caps reading width so iPad and Mac layouts don't stretch edge to edge.
    func contentColumn(_ maxWidth: CGFloat = 640) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

enum Platform {
    /// Opens the system's privacy settings so the user can grant calendar,
    /// reminders, or location access after denying the prompt.
    static func openPrivacySettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// Opens where accounts are added (Settings on iOS, Internet Accounts on macOS),
    /// which is how Google / Exchange / other calendar accounts reach EventKit.
    static func openAccountSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// Opens a URL with the platform's opener (webcal holiday feeds, Join links, map links).
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

import SwiftUI

// Shims for APIs that exist on iOS/iPadOS but not on native macOS, so the
// shared views stay free of #if noise.
extension View {
    /// Half-height sheet where detents exist; a fixed-size window sheet on macOS.
    @ViewBuilder
    func mediumSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 460, minHeight: 480)
        #else
        presentationDetents([.medium])
        #endif
    }

    /// Medium sheet the user can pull to full height; sized window sheet on macOS.
    @ViewBuilder
    func mediumOrLargeSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 460, minHeight: 540)
        #else
        presentationDetents([.medium, .large])
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

    @ViewBuilder
    func decimalPadKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.decimalPad)
        #endif
    }

    /// Caps reading width so iPad and Mac layouts don't stretch edge to edge.
    func contentColumn() -> some View {
        frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }
}

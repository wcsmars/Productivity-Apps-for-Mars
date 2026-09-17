import SwiftUI

/// "All + category" capsule chips, shared by the Progress and Calendar tabs.
struct CategoryFilterChips: View {
    @Binding var filter: TrackerCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: filter == nil) { filter = nil }
                ForEach(TrackerCategory.allCases) { category in
                    chip(title: category.title, isSelected: filter == category) { filter = category }
                }
            }
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.wine : Theme.blush, in: Capsule())
                .foregroundStyle(isSelected ? .white : Theme.wineDeep)
        }
        .buttonStyle(.plain)
    }
}
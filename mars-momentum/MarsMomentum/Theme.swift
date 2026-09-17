import SwiftUI

/// Wine red & white palette used across the app.
enum Theme {
    /// Primary wine red (#722F37).
    static let wine = Color(red: 114 / 255, green: 47 / 255, blue: 55 / 255)
    /// Deep wine used for headings and the gym category (#46151D).
    static let wineDeep = Color(red: 70 / 255, green: 21 / 255, blue: 29 / 255)
    /// Lighter rose used for the cardio category (#B14D5E).
    static let rose = Color(red: 177 / 255, green: 77 / 255, blue: 94 / 255)
    /// Soft blush used for card backgrounds (#F9F2F3).
    static let blush = Color(red: 249 / 255, green: 242 / 255, blue: 243 / 255)
    /// Empty heatmap cell.
    static let emptyCell = Color(red: 0.925, green: 0.925, blue: 0.925)

    /// Heatmap fill for an intensity level (0 = empty ... 4 = max).
    static func heat(_ level: Int) -> Color {
        switch level {
        case 1: wine.opacity(0.25)
        case 2: wine.opacity(0.5)
        case 3: wine.opacity(0.75)
        case 4: wine
        default: emptyCell
        }
    }
}

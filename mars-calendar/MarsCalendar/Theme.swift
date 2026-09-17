import SwiftUI

/// Wine red & white palette shared with Mars Momentum and Mars Focus.
enum Theme {
    /// Primary wine red (#722F37).
    static let wine = Color(red: 114 / 255, green: 47 / 255, blue: 55 / 255)
    /// Deep wine used for headings and the Work calendar (#46151D).
    static let wineDeep = Color(red: 70 / 255, green: 21 / 255, blue: 29 / 255)
    /// Lighter rose used for the Fitness calendar (#B14D5E).
    static let rose = Color(red: 177 / 255, green: 77 / 255, blue: 94 / 255)
    /// Soft blush used for card backgrounds (#F9F2F3).
    static let blush = Color(red: 249 / 255, green: 242 / 255, blue: 243 / 255)
    /// Muted mauve for de-emphasized accents like the Eliminate quadrant (#8F7D82).
    static let mauve = Color(red: 0.56, green: 0.49, blue: 0.51)
    /// Neutral fill for week-view timeline separators.
    static let emptyCell = Color(red: 0.925, green: 0.925, blue: 0.925)
}

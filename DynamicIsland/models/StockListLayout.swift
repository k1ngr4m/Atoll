import Foundation

enum StockListLayout {
    static let rowHeight: CGFloat = 48
    static let spacing: CGFloat = 8
    static let chartHeight: CGFloat = 135

    static func listHeight(count: Int) -> CGFloat {
        let rows = max(1, min(count, 8))
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
    }

    static func height(count: Int, chartCollapsed: Bool, headerHeight: CGFloat) -> CGFloat {
        // Header gap, input, footer, vertical spacing, and bottom inset.
        let controlsHeight: CGFloat = 72
        let chart = count > 0 && !chartCollapsed ? chartHeight + spacing : 0
        return max(24, headerHeight) + controlsHeight + listHeight(count: count) + chart
    }
}

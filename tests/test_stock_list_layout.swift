// Run: swiftc DynamicIsland/models/StockListLayout.swift tests/test_stock_list_layout.swift -o /tmp/test-stock-layout && /tmp/test-stock-layout
import Foundation

@main
struct StockListLayoutTests {
    static func main() {
        func height(_ count: Int, collapsed: Bool = true) -> CGFloat {
            StockListLayout.height(count: count, chartCollapsed: collapsed, headerHeight: 32)
        }
        for count in 1..<8 {
            assert(height(count + 1) - height(count) == 56)
        }
        assert(StockListLayout.listHeight(count: 8) == 440)
        assert(height(9) == height(8))
        assert(height(100) == height(8))
        assert(height(2) < height(8))
        assert(height(8, collapsed: false) - height(8) == 143)
        assert(height(0, collapsed: false) == height(0))
        assert(height(0) == height(1))
        print("Stock list layout checks passed")
    }
}

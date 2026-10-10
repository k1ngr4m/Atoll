import Foundation

struct StockIntraday {
    struct Point: Identifiable {
        let minute: Int
        let price: Double
        var id: Int { minute }
    }
    let date: String
    let previousClose: Double?
    let points: [Point]

    static func decode(_ data: Data, symbol: String) throws -> StockIntraday {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["code"] as? Int == 0,
              let payload = root["data"] as? [String: Any],
              let stock = payload[symbol] as? [String: Any],
              let series = stock["data"] as? [String: Any],
              let date = series["date"] as? String,
              date.range(of: #"^[0-9]{8}$"#, options: .regularExpression) != nil,
              let rows = series["data"] as? [String] else { throw StockQuote.QuoteError.invalidResponse }
        var points: [Point] = []
        for row in rows {
            let fields = row.split(separator: " ")
            guard fields.count >= 2, fields[0].count == 4,
                  let hour = Int(fields[0].prefix(2)), let minute = Int(fields[0].suffix(2)),
                  (0..<24).contains(hour), (0..<60).contains(minute),
                  let price = Double(fields[1]), price.isFinite, price > 0 else {
                throw StockQuote.QuoteError.invalidResponse
            }
            let time = hour * 60 + minute
            let offset: Int
            if (570...690).contains(time) { offset = time - 570 }
            else if (780...900).contains(time) { offset = time - 660 }
            else { continue } // Auction points are outside the continuous-session chart.
            guard offset >= (points.last?.minute ?? -1) else { throw StockQuote.QuoteError.invalidResponse }
            if points.last?.minute == offset { points.removeLast() }
            points.append(Point(minute: offset, price: price))
        }
        let qt = stock["qt"] as? [String: Any]
        let fields = qt?[symbol] as? [String]
        let previous = fields.flatMap { $0.count > 4 ? Double($0[4]) : nil }
        return StockIntraday(date: date, previousClose: previous.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, points: points)
    }
}

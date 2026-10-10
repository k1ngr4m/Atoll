// Run: swiftc DynamicIsland/models/StockQuote.swift DynamicIsland/models/StockIntraday.swift tests/test_stock_quote.swift -o /tmp/test-stock && /tmp/test-stock
import Foundation
import CoreFoundation

@main
struct StockQuoteTests {
    static func main() throws {
        assert(StockQuote.normalizedCode(" 600000.sh ") == "600000.SH")
        assert(StockQuote.requestSymbol("920001.BJ") == "bj920001")
        for code in ["600000", "601398", "603000", "605001", "688001"] {
            assert(StockQuote.normalizedCode(code) == code + ".SH")
            assert(StockQuote.requestSymbol(code) == "sh" + code)
        }
        for code in ["000001", "001001", "002001", "003001", "300001", "301001"] {
            assert(StockQuote.normalizedCode(code) == code + ".SZ")
            assert(StockQuote.requestSymbol(code) == "sz" + code)
        }
        assert(StockQuote.requestSymbol(" 920001 ") == "bj920001")
        assert(StockQuote.normalizedCode("600000") == StockQuote.normalizedCode("600000.SH"))
        assert(StockQuote.normalizedCode("000001.SH") == "000001.SH")
        for code in ["123456", "60000", "6000000", "６０００００", "600 000", "900001", "6*.SH", "600000.SH,000001.SZ", "12345.SZ", "123456.US"] {
            assert(StockQuote.requestSymbol(code) == nil)
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        func record(_ symbol: String, _ name: String, _ price: String, _ previous: String) -> String {
            var fields = Array(repeating: "", count: 33)
            fields[0] = "1"; fields[1] = name; fields[2] = String(symbol.dropFirst(2))
            fields[3] = price; fields[4] = previous; fields[30] = "20261009150000"
            return "v_\(symbol)=\"\(fields.joined(separator: "~"))\";\n"
        }
        let valid = record("sh600000", "浦发银行", "11", "10")
        let text = valid + record("sz000001", "平安银行", "9", "10")
            + record("bj920001", "纬达光电", "0", "0") + "v_pv_none_match=\"1\";"
        let quotes = try StockQuote.decode(text.data(using: encoding)!)
        assert(quotes.count == 3 && quotes[0].name == "浦发银行")
        assert(quotes[0].change == 1 && quotes[0].percent == 10)
        assert(quotes[0].tradeTime == "2026-10-09 15:00:00")
        assert(quotes[1].id == "000001.SZ" && quotes[1].percent == -10)
        assert(quotes[2].id == "920001.BJ" && quotes[2].price == nil && quotes[2].percent == nil)
        assert(tryEmpty("v_pv_none_match=\"1\";"))
        for bad in ["", "<html>Blocked</html>", "v_sh600000=\"1~name\";",
                    valid.replacingOccurrences(of: "20261009150000", with: "20261399150000"),
                    record("sh600000", "Bank", "NaN", "10"),
                    record("sh600000", "Bank", "-1", "10"),
                    valid.replacingOccurrences(of: "~600000~", with: "~000001~")] {
            do { _ = try StockQuote.decode(bad.data(using: encoding)!); fatalError("Expected rejection") }
            catch { }
        }
        if CommandLine.arguments.count > 1 {
            let live = try StockQuote.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            assert(Set(live.map(\.id)) == ["600000.SH", "000001.SZ", "920001.BJ"])
            assert(live.allSatisfy { $0.price != nil && $0.tradeTime != nil })
            print("Live Tencent response decoded: \(live.count) quotes")
        }
        let minuteJSON = #"{"code":0,"data":{"sh600000":{"data":{"date":"20261009","data":["0925 10 0","0930 10 10","1130 11 20","1300 12 30","1500 9 40"]},"qt":{"sh600000":["1","Bank","600000","9","10"]}}}}"#
        let series = try StockIntraday.decode(Data(minuteJSON.utf8), symbol: "sh600000")
        assert(series.points.map(\.minute) == [0, 120, 240])
        assert(series.points.map(\.price) == [10, 12, 9])
        assert(series.previousClose == 10 && series.date == "20261009")
        for bad in [minuteJSON.replacingOccurrences(of: "0930 10", with: "0960 10"),
                    minuteJSON.replacingOccurrences(of: "0930 10", with: "0930 NaN"),
                    minuteJSON.replacingOccurrences(of: "1500 9", with: "1000 9"),
                    "{\"code\":1}"] {
            do { _ = try StockIntraday.decode(Data(bad.utf8), symbol: "sh600000"); fatalError("Expected invalid chart rejection") }
            catch { }
        }
        if CommandLine.arguments.count > 3 {
            let liveChart = try StockIntraday.decode(
                Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), symbol: CommandLine.arguments[3])
            assert(!liveChart.points.isEmpty && liveChart.previousClose != nil)
            print("Live intraday response decoded: \(liveChart.points.count) points")
        }
        print("Stock quote and intraday tests passed")
    }

    static func tryEmpty(_ text: String) -> Bool {
        (try? StockQuote.decode(Data(text.utf8)).isEmpty) == true
    }
}

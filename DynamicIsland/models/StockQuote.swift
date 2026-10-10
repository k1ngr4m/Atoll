import Foundation
import CoreFoundation

struct StockQuote: Identifiable {
    let id: String
    let name: String
    let price: Double?
    let previousClose: Double?
    let tradeTime: String?

    var change: Double? {
        guard let price, let previousClose, previousClose > 0 else { return nil }
        return price - previousClose
    }
    var percent: Double? {
        guard let change, let previousClose else { return nil }
        return change / previousClose * 100
    }

    static func normalizedCode(_ input: String) -> String? {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.range(of: #"^[0-9]{6}\.(SH|SZ|BJ)$"#, options: .regularExpression) != nil {
            return code
        }
        guard code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        // A-share code ranges only; explicit suffixes remain available for other instruments.
        if code.hasPrefix("60") || code.hasPrefix("68") { return code + ".SH" }
        if code.hasPrefix("00") || code.hasPrefix("30") { return code + ".SZ" }
        if code.hasPrefix("920") { return code + ".BJ" }
        return nil
    }

    static func requestSymbol(_ input: String) -> String? {
        guard let code = normalizedCode(input) else { return nil }
        return code.suffix(2).lowercased() + code.prefix(6)
    }

    static func decode(_ data: Data) throws -> [StockQuote] {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: encoding),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw QuoteError.invalidResponse }
        let dateParser = DateFormatter()
        dateParser.locale = Locale(identifier: "en_US_POSIX")
        dateParser.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dateParser.dateFormat = "yyyyMMddHHmmss"
        dateParser.isLenient = false
        let displayDate = DateFormatter()
        displayDate.locale = dateParser.locale
        displayDate.timeZone = dateParser.timeZone
        displayDate.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // ponytail: Tencent's positional web format; update this parser if the provider changes it.
        return try text.components(separatedBy: ";").compactMap { statement in
            let line = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "v_pv_none_match=\"1\"" { return nil }
            guard let separator = line.range(of: "=\""), line.hasSuffix("\"") else {
                throw QuoteError.invalidResponse
            }
            let key = String(line[..<separator.lowerBound])
            guard key.range(of: #"^v_(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil else {
                throw QuoteError.invalidResponse
            }
            let symbol = String(key.dropFirst(2))
            let code = String(symbol.dropFirst(2))
            let fields = line[separator.upperBound..<line.index(before: line.endIndex)]
                .components(separatedBy: "~")
            guard fields.count > 30, fields[2] == code, !fields[1].isEmpty else {
                throw QuoteError.invalidResponse
            }
            func number(_ index: Int) throws -> Double? {
                let raw = fields[index]
                if raw.isEmpty || raw == "-" { return nil }
                guard let value = Double(raw), value.isFinite, value >= 0 else {
                    throw QuoteError.invalidResponse
                }
                return value > 0 ? value : nil
            }
            let time = fields[30]
            var tradeTime: String?
            if !time.isEmpty {
                guard time.count == 14, let date = dateParser.date(from: time),
                      dateParser.string(from: date) == time else { throw QuoteError.invalidResponse }
                tradeTime = displayDate.string(from: date)
            }
            return try StockQuote(id: code + "." + symbol.prefix(2).uppercased(),
                                  name: fields[1], price: number(3), previousClose: number(4),
                                  tradeTime: tradeTime)
        }
    }

    enum QuoteError: LocalizedError {
        case invalidResponse
        var errorDescription: String? {
            String(localized: "Invalid stock quote response. Please try again later.")
        }
    }
}

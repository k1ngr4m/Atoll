import Foundation
import Combine
import Defaults

@MainActor
final class StockManager: ObservableObject {
    static let shared = StockManager()
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var missingCodes: Set<String> = []
    @Published private(set) var intraday: [String: StockIntraday] = [:]
    @Published private(set) var chartErrors: [String: String] = [:]
    @Published private(set) var loadingCharts: Set<String> = []
    private var lastRefreshAttempt: Date?

    func refreshIntraday(_ code: String) async {
        guard !loadingCharts.contains(code), let symbol = StockQuote.requestSymbol(code) else { return }
        loadingCharts.insert(code)
        chartErrors[code] = nil
        defer { loadingCharts.remove(code) }
        do {
            let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=" + symbol)!
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            intraday[code] = try StockIntraday.decode(data, symbol: symbol)
        } catch {
            if !Task.isCancelled { chartErrors[code] = error.localizedDescription }
        }
    }

    func refresh(force: Bool = true) async {
        guard !isLoading else { return }
        if !force, let lastRefreshAttempt, Date().timeIntervalSince(lastRefreshAttempt) < 25 { return }
        let codes = Defaults[.stockWatchlist]
        guard !codes.isEmpty else { error = nil; return }
        lastRefreshAttempt = Date()
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let symbols = codes.compactMap(StockQuote.requestSymbol)
            guard symbols.count == codes.count else { throw StockQuote.QuoteError.invalidResponse }
            var fetched: [StockQuote] = []
            // Keep URLs short even for long watchlists; no full-market download.
            for start in stride(from: 0, to: symbols.count, by: 50) {
                let batch = symbols[start..<min(start + 50, symbols.count)].joined(separator: ",")
                guard let url = URL(string: "https://qt.gtimg.cn/q=" + batch) else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                fetched += try StockQuote.decode(data)
            }
            let wanted = Set(Defaults[.stockWatchlist])
            let returned = Set(fetched.map(\.id))
            missingCodes = Set(codes).intersection(wanted).subtracting(returned)
            quotes = quotes.filter { wanted.contains($0.key) }
            for quote in fetched where wanted.contains(quote.id) { quotes[quote.id] = quote }
            refreshedAt = Date()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

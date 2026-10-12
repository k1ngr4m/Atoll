import SwiftUI
import Defaults

struct NotchStocksView: View {
    @ObservedObject private var manager = StockManager.shared
    @Default(.stockWatchlist) private var watchlist
    @Default(.stockPinnedCode) private var pinnedCode
    @Default(.stockChartCollapsed) private var isChartCollapsed
    @Default(.stockSelectedCode) private var selectedCode
    @State private var code = ""

    private var activeCode: String? {
        guard !isChartCollapsed else { return nil }
        if let selectedCode, watchlist.contains(selectedCode) { return selectedCode }
        return watchlist.contains(pinnedCode) ? pinnedCode : watchlist.first
    }
    @State private var inputError: String?
    @State private var refreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Six-digit code, e.g. 600000", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addStock)
                Button("Add", action: addStock)
                    .disabled(manager.isLoading)
                Button { refreshID = UUID() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("Refresh stocks"))
                .disabled(manager.isLoading || watchlist.isEmpty)
                if manager.isLoading { ProgressView().controlSize(.small) }
            }
            if let message = inputError ?? manager.error {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if watchlist.isEmpty {
                Text("Enter a six-digit A-share code. The exchange is detected automatically; suffixes are optional.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: StockListLayout.spacing) {
                        ForEach(watchlist, id: \.self) { symbol in
                            row(symbol)
                        }
                    }
                }
                .frame(maxHeight: StockListLayout.listHeight(count: watchlist.count))
            }
            if let activeCode {
                StockIntradayView(code: activeCode, onCollapse: { isChartCollapsed = true })
                    .frame(height: StockListLayout.chartHeight)
                    .task(id: activeCode) { await manager.refreshIntraday(activeCode) }
            }
            HStack {
                Text("Tencent quotes · Refreshes when opened")
                Spacer()
                if let date = manager.refreshedAt {
                    Text("Fetched \(date.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { Task { await manager.refresh() } }
        .onChange(of: refreshID) { _, _ in
            Task {
                await manager.refresh()
                if let activeCode { await manager.refreshIntraday(activeCode) }
            }
        }
    }

    private func addStock() {
        guard !manager.isLoading else { return }
        guard let symbol = StockQuote.normalizedCode(code) else {
            inputError = String(localized: "Enter a valid six-digit A-share code, or specify .SH, .SZ or .BJ.")
            return
        }
        guard !watchlist.contains(symbol) else {
            inputError = String(localized: "This stock is already in your watchlist.")
            return
        }
        watchlist.append(symbol)
        selectedCode = symbol
        code = ""
        inputError = nil
        refreshID = UUID()
    }

    private func row(_ symbol: String) -> some View {
        let quote = manager.quotes[symbol]
        let change = quote?.change
        let color: Color = change.map { $0 > 0 ? .red : ($0 < 0 ? .green : .secondary) } ?? .secondary
        return HStack(spacing: 12) {
            Button { isChartCollapsed = false; selectedCode = symbol } label: {
                Image(systemName: activeCode == symbol ? "chart.xyaxis.line" : "chart.line.uptrend.xyaxis")
                    .foregroundStyle(activeCode == symbol ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show intraday chart for \(symbol)"))
            VStack(alignment: .leading, spacing: 2) {
                Text(quote?.name ?? symbol).font(.callout).lineLimit(1)
                Text(symbol).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    Text(quote?.price.map { String(format: "%.2f", $0) } ?? "—")
                    Text(quote?.percent.map { String(format: "%+.2f%%", $0) } ?? "—")
                    Text(change.map { String(format: "%+.2f", $0) } ?? "—")
                }
                .monospacedDigit().foregroundStyle(color)
                if manager.missingCodes.contains(symbol) {
                    Text("No new quote").font(.caption2).foregroundStyle(.orange)
                } else if let time = quote?.tradeTime {
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { pinnedCode = pinnedCode == symbol ? "" : symbol } label: {
                Image(systemName: pinnedCode == symbol ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinnedCode == symbol ? Text("Unpin \(symbol)") : Text("Pin \(symbol) on closed notch"))
            Button {
                if pinnedCode == symbol { pinnedCode = "" }
                watchlist.removeAll { $0 == symbol }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(symbol)"))
        }
        .padding(8)
        .frame(height: StockListLayout.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { isChartCollapsed = false; selectedCode = symbol }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StocksSettingsSection: View {
    @Default(.enableStocksFeature) private var enabled
    @Default(.stockWatchlist) private var watchlist
    @Default(.stockPinnedCode) private var pinnedCode

    var body: some View {
        Section {
            Defaults.Toggle(key: .enableStocksFeature) { Text("Enable A-share stocks") }
                .onChange(of: enabled) { _, value in
                    if !value && DynamicIslandViewCoordinator.shared.currentView == .stocks {
                        DynamicIslandViewCoordinator.shared.currentView = .home
                    }
                }
            if enabled {
                Defaults.Toggle(key: .stockShowWhenClosed) { Text("Show stock price when closed") }
                Picker("Pinned stock", selection: $pinnedCode) {
                    Text("No pinned stock").tag("")
                    ForEach(watchlist, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: watchlist) { _, codes in
                    if !codes.contains(pinnedCode) { pinnedCode = "" }
                }
            }
        } header: {
            Text("Stocks")
        } footer: {
            Text("Uses Tencent web quotes without a Token. Select a stock to view its intraday chart. The pinned price refreshes every 30 seconds while visible on the closed notch. Temporary activities take priority. Quotes may be delayed; check the quote time.")
        }
    }
}

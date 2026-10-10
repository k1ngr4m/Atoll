import SwiftUI

struct StockIntradayView: View {
    let code: String
    let onCollapse: () -> Void
    @ObservedObject private var manager = StockManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Intraday · \(code)").font(.caption.weight(.semibold))
                Spacer()
                Button("Collapse intraday chart", action: onCollapse)
                    .buttonStyle(.borderless)
                    .font(.caption)
                if manager.loadingCharts.contains(code) { ProgressView().controlSize(.mini) }
                if let series = manager.intraday[code] { Text(series.date).font(.caption2).foregroundStyle(.secondary) }
            }
            if let error = manager.chartErrors[code] {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            if let series = manager.intraday[code], !series.points.isEmpty {
                plot(series)
            } else {
                Text("No intraday data").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func plot(_ series: StockIntraday) -> some View {
        let prices = series.points.map(\.price) + (series.previousClose.map { [$0] } ?? [])
        let low = prices.min() ?? 0
        let high = prices.max() ?? 1
        let padding = max((high - low) * 0.1, max(high * 0.001, 0.01))
        let lower = low - padding
        let upper = high + padding
        let color: Color = (series.points.last?.price ?? 0) >= (series.previousClose ?? series.points[0].price) ? .red : .green
        return HStack(spacing: 6) {
            VStack(alignment: .trailing) {
                Text(String(format: "%.2f", upper))
                Spacer()
                Text(String(format: "%.2f", lower))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            .padding(.bottom, 16)
            VStack(spacing: 3) {
                Canvas { context, size in
                    func position(_ point: StockIntraday.Point) -> CGPoint {
                        CGPoint(x: CGFloat(point.minute) / 240 * size.width,
                                y: (upper - point.price) / (upper - lower) * size.height)
                    }
                    if let previous = series.previousClose {
                        let y = (upper - previous) / (upper - lower) * size.height
                        var baseline = Path()
                        baseline.move(to: CGPoint(x: 0, y: y))
                        baseline.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(baseline, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    var line = Path()
                    for (index, point) in series.points.enumerated() {
                        if index == 0 { line.move(to: position(point)) }
                        else { line.addLine(to: position(point)) }
                    }
                    context.stroke(line, with: .color(color), lineWidth: 1.5)
                    if let last = series.points.last {
                        let p = position(last)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color))
                    }
                }
                .accessibilityLabel(Text("Intraday price chart"))
                .accessibilityValue(Text("Low \(String(format: "%.2f", low)), high \(String(format: "%.2f", high))"))
                HStack {
                    Text(verbatim: "09:30")
                    Spacer()
                    Text(verbatim: "11:30 / 13:00")
                    Spacer()
                    Text(verbatim: "15:00")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ClosedStockView: View {
    let code: String
    let centerWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var manager = StockManager.shared

    var body: some View {
        let quote = manager.quotes[code]
        let color: Color = (quote?.change ?? 0) > 0 ? .red : ((quote?.change ?? 0) < 0 ? .green : .secondary)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(color)
                Text(quote?.name ?? String(code.prefix(6))).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .frame(width: 126)
            Color.clear.frame(width: max(centerWidth, 96))
            HStack(spacing: 4) {
                Text(quote?.price.map { String(format: "%.2f", $0) } ?? "—")
                Text(quote?.percent.map { String(format: "%+.2f%%", $0) } ?? "—")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(color)
            .monospacedDigit().frame(width: 126)
        }
        .frame(height: max(height, 24))
        .help(manager.error != nil || manager.missingCodes.contains(code)
              ? String(localized: "Quote update failed")
              : (quote?.tradeTime ?? String(localized: "No new quote")))
        .task(id: code) {
            while !Task.isCancelled {
                await manager.refresh(force: false)
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Card layout and activity presentation adapted from Vorssaint's NotchAgentsView.
// Copyright (C) 2026 Vorssaint.

import SwiftUI

struct CodexUsageDetailView: View {
    @ObservedObject private var manager = LLMUsageManager.shared
    @State private var period: CodexUsagePeriod = .today
    @State private var allTasks = false
    @State private var allModels = false
    @State private var allProjects = false
    @State private var hoveredBucket: Date?
    @State private var hoveredDay: Date?
    let onBack: () -> Void
    private let accent = Color(red: 0.49, green: 0.56, blue: 0.94)

    private var snapshot: UsageSnapshot? {
        if case .success(let value) = manager.results[.codex] { return value }
        return nil
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back to usage"))
                    .help("Back to usage")
                Text("Codex").font(.headline)
                Spacer()
                Picker("Usage period", selection: $period) {
                    ForEach(CodexUsagePeriod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            GeometryReader { geometry in
                ScrollView {
                    if let snapshot {
                        dashboard(snapshot, wide: geometry.size.width >= 520)
                    } else if case .failure(let error) = manager.results[.codex] {
                        VStack(spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await manager.refreshCodexDetail() } }
                        }.frame(maxWidth: .infinity).padding()
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                await manager.refreshCodexDetail()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: period) { _, _ in hoveredBucket = nil }
    }

    private func dashboard(_ snapshot: UsageSnapshot, wide: Bool) -> some View {
        VStack(spacing: 10) {
            limits(snapshot)
            if snapshot.isLocalUsageLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading local usage…").font(.caption) }.padding()
            }
            if let error = snapshot.localUsageError {
                Text(error).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details = snapshot.codexDetails {
                let usage = details.periods[period] ?? CodexPeriodUsage()
                pair(wide: wide) {
                    spend(usage.totals)
                    live(details.tasks)
                }
                trend(details, totals: usage.totals)
                pair(wide: wide) {
                    shares("Models", symbol: "cpu", values: usage.models, byCost: !usage.totals.hasUnpricedModel, expanded: $allModels)
                    shares("Projects", symbol: "folder", values: usage.projects, byCost: !usage.totals.hasUnpricedModel, expanded: $allProjects)
                }
                activity(details, wide: wide)
            }
        }
        .padding(.trailing, 3)
    }

    @ViewBuilder private func pair<Content: View>(wide: Bool, @ViewBuilder content: () -> Content) -> some View {
        if wide { HStack(alignment: .top, spacing: 10, content: content) }
        else { VStack(spacing: 10, content: content) }
    }

    private func card<Content: View>(_ title: LocalizedStringKey, symbol: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 0.7) }
    }

    private func limits(_ snapshot: UsageSnapshot) -> some View {
        card("Codex", symbol: "chevron.left.forwardslash.chevron.right") {
            if let plan = snapshot.plan {
                Text(plan).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.15), in: Capsule())
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    if let limit = snapshot.sessionLimit { limitRow("Session", limit: limit, now: context.date) }
                    if let limit = snapshot.weekLimit { limitRow("Week", limit: limit, now: context.date) }
                }
            }
            if snapshot.sessionLimit == nil && snapshot.weekLimit == nil {
                Text("quota unavailable").font(.caption).foregroundStyle(.secondary)
            }
            if let updated = snapshot.quotaUpdatedAt {
                HStack(spacing: 4) {
                    if snapshot.quotaIsStale { Image(systemName: "clock.arrow.circlepath"); Text("Last known quota") }
                    Text("Updated")
                    Text(updated, style: .relative)
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func limitRow(_ title: LocalizedStringKey, limit: UsageLimit, now: Date) -> some View {
        let remaining = max(0, min(1, 1 - limit.fraction))
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                if let reset = limit.resetsAt {
                    if reset > now {
                        Label(duration(reset.timeIntervalSince(now)), systemImage: "arrow.clockwise")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(reset.formatted(date: .abbreviated, time: .shortened))
                    } else { Text("Awaiting quota refresh").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 2)
                Text("Remaining").font(.caption2).foregroundStyle(.secondary)
                Text(remaining.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 16, weight: .bold, design: .rounded))
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.12)).overlay(alignment: .leading) {
                    Capsule().fill(remaining <= 0.1 ? .orange : accent).frame(width: geometry.size.width * remaining)
                }
            }.frame(height: 7)
        }
        .accessibilityElement(children: .combine)
    }

    private func spend(_ totals: UsageTotals) -> some View {
        card("Spend", symbol: "dollarsign.circle") {
            VStack(alignment: .leading, spacing: 5) {
                Text(money(totals.costUSD)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("Estimated API value").font(.caption).foregroundStyle(.secondary)
                Text(tokens(totals.totalTokens) + " " + String(localized: "tokens")).font(.caption).foregroundStyle(accent)
                if totals.hasUnpricedModel { Text("Priced models only").font(.caption2).foregroundStyle(.orange) }
            }.frame(minHeight: 76, alignment: .topLeading)
        }
    }

    private func live(_ tasks: [CodexLiveTask]) -> some View {
        card("Current tasks", symbol: "waveform.path.ecg") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    if tasks.isEmpty { Text("No active Codex tasks").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(tasks.prefix(allTasks ? tasks.count : 2))) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(context.date.timeIntervalSince(task.lastActivity) > 300 ? .gray : accent).frame(width: 5, height: 5)
                                Text(projectName(task.project)).font(.caption.weight(.semibold)).lineLimit(1).help(task.project)
                                Spacer(minLength: 3)
                                Text(duration(context.date.timeIntervalSince(task.started))).foregroundStyle(accent).monospacedDigit().font(.caption)
                            }
                            Text(task.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("Output tokens")
                                Text(tokens(task.totals.outputTokens))
                                Text(verbatim: "· " + money(task.totals.costUSD))
                            }.font(.caption2).foregroundStyle(.secondary)
                            if task.totals.hasUnpricedModel { Text("Priced models only").font(.caption2).foregroundStyle(.orange) }
                            if context.date.timeIntervalSince(task.lastActivity) > 300 {
                                Text("Waiting for updates").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                    if tasks.count > 2 { expansionButton($allTasks) }
                }.frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            }
        }
    }

    private func trend(_ details: CodexUsageDetails, totals: UsageTotals) -> some View {
        let buckets = period == .today ? details.hours : Array(details.days.suffix(period.rawValue))
        let byCost = !totals.hasUnpricedModel
        let peak = max(buckets.map { $0.totals.weight(byCost: byCost) }.max() ?? 0, 1e-9)
        let selected = buckets.first { $0.start == hoveredBucket }
        return card("Trend", symbol: "chart.bar.fill") {
            HStack {
                Text(selected.map { bucketDate($0.start) } ?? period.title)
                Spacer()
                Text(selected.map { bucketDescription($0) } ?? value(totals, byCost: byCost))
            }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(buckets) { bucket in
                    let height = max(2, 70 * bucket.totals.weight(byCost: byCost) / peak)
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(bucket.start == hoveredBucket ? 1 : 0.55))
                        .frame(maxWidth: .infinity).frame(height: height)
                        .frame(height: 72, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { hoveredBucket = $0 ? bucket.start : nil }
                        .help(bucketDate(bucket.start) + " · " + bucketDescription(bucket))
                        .accessibilityLabel(bucketDate(bucket.start))
                        .accessibilityValue(bucketDescription(bucket))
                }
            }
            HStack {
                Text(buckets.first.map { bucketDate($0.start) } ?? "")
                Spacer()
                Text(buckets.last.map { bucketDate($0.start) } ?? "")
            }.font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func shares(_ title: LocalizedStringKey, symbol: String, values: [CodexUsageShare],
                        byCost: Bool, expanded: Binding<Bool>) -> some View {
        let peak = max(values.first?.totals.weight(byCost: byCost) ?? 0, 1e-9)
        return card(title, symbol: symbol) {
            VStack(spacing: 9) {
                if values.isEmpty { Text("No usage in this period").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(values.prefix(expanded.wrappedValue ? values.count : 3))) { share in
                    HStack(spacing: 8) {
                        Text(share.name).lineLimit(1).help(share.id)
                        Spacer(minLength: 0)
                        Capsule().fill(accent).frame(width: max(2, 40 * share.totals.weight(byCost: byCost) / peak), height: 4).accessibilityHidden(true)
                        Text(value(share.totals, byCost: byCost)).foregroundStyle(.secondary).monospacedDigit()
                    }.font(.caption).accessibilityElement(children: .combine)
                }
                if values.count > 3 { expansionButton(expanded) }
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        }
    }

    private func activity(_ details: CodexUsageDetails, wide: Bool) -> some View {
        let peak = max(details.days.map { $0.totals.totalTokens }.max() ?? 0, 1)
        let day = details.days.first { $0.start == hoveredDay } ?? details.busiestDay
        return card("Activity", symbol: "square.grid.3x3.fill") {
            pair(wide: wide) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(12), spacing: 3), count: 7), spacing: 3) {
                    ForEach(details.days) { bucket in
                        heatmapCell(bucket, peak: peak)
                    }
                }.frame(width: 192, height: 102)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(tokens(details.total.totalTokens)).font(.system(size: 24, weight: .semibold, design: .rounded))
                        Spacer()
                        if details.streak > 0 {
                            Label("\(details.streak)", systemImage: "flame.fill").foregroundStyle(.orange)
                                .accessibilityLabel(Text("Consecutive active days"))
                                .accessibilityValue("\(details.streak)")
                                .help("Consecutive active days")
                        }
                    }
                    Text("13 weeks").foregroundStyle(.secondary)
                    HStack { Text("Active days").foregroundStyle(.secondary); Spacer(); Text("\(details.activeDays)") }
                    if let day {
                        HStack {
                            Text(hoveredDay == nil ? "Busiest day" : "Selected day").foregroundStyle(.secondary)
                            Spacer()
                            Text(day.start.formatted(.dateTime.month().day()) + " · " + tokens(day.totals.totalTokens))
                        }
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func heatmapCell(_ bucket: CodexUsageBucket, peak: Int) -> some View {
        let fraction = sqrt(Double(bucket.totals.totalTokens) / Double(peak))
        let opacity = bucket.totals.totalTokens == 0 ? 0.07 : 0.18 + 0.82 * fraction
        let label = bucket.start.formatted(date: .abbreviated, time: .omitted)
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(opacity))
            .frame(width: 12, height: 12)
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(hoveredDay == bucket.start ? accent : .clear) }
            .onHover { hoveredDay = $0 ? bucket.start : nil }
            .help(label + " · " + bucketDescription(bucket))
            .accessibilityLabel(label)
            .accessibilityValue(bucketDescription(bucket))
    }

    private func expansionButton(_ expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            Text(expanded.wrappedValue ? "Show less" : "Show all")
        }.buttonStyle(.plain).foregroundStyle(accent).font(.caption)
    }

    private func tokens(_ value: Int) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    private func value(_ totals: UsageTotals, byCost: Bool) -> String { byCost ? money(totals.costUSD) : tokens(totals.totalTokens) }
    private func projectName(_ path: String) -> String { path.isEmpty ? String(localized: "Unknown project") : URL(fileURLWithPath: path).lastPathComponent }
    private func bucketDate(_ date: Date) -> String { period == .today ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.month().day()) }
    private func bucketDescription(_ bucket: CodexUsageBucket) -> String {
        tokens(bucket.totals.totalTokens) + " " + String(localized: "tokens") + " · " + money(bucket.totals.costUSD)
            + (bucket.totals.hasUnpricedModel ? " (" + String(localized: "Priced models only") + ")" : "")
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, seconds)) ?? "0s"
    }
}

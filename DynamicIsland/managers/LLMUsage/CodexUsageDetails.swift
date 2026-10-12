// SPDX-License-Identifier: GPL-3.0-or-later
// Codex parsing and dashboard aggregation adapted from Vorssaint's
// AgentLogParser / AgentUsageSummary. Copyright (C) 2026 Vorssaint.

import Foundation
import Darwin

enum CodexUsagePeriod: Int, CaseIterable, Identifiable {
    case today = 1, week = 7, month = 30
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "Last 7 days")
        case .month: return String(localized: "Last 30 days")
        }
    }
}

extension UsageTotals {
    mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        costUSD += other.costUSD
        hasUnpricedModel = hasUnpricedModel || other.hasUnpricedModel
    }
    func weight(byCost: Bool) -> Double { byCost ? costUSD : Double(totalTokens) }
}

struct CodexUsageBucket: Equatable, Identifiable {
    let start: Date
    var totals = UsageTotals()
    var id: Date { start }
}

struct CodexUsageShare: Equatable, Identifiable {
    let id: String
    let name: String
    var totals = UsageTotals()
}

struct CodexPeriodUsage: Equatable {
    var totals = UsageTotals()
    var models: [CodexUsageShare] = []
    var projects: [CodexUsageShare] = []
}

struct CodexLiveTask: Equatable, Identifiable {
    let id: String
    let started: Date
    var lastActivity: Date
    var model: String
    var project: String
    var totals = UsageTotals()
}

struct CodexUsageDetails: Equatable {
    var periods: [CodexUsagePeriod: CodexPeriodUsage] = [:]
    var days: [CodexUsageBucket] = []
    var hours: [CodexUsageBucket] = []
    var tasks: [CodexLiveTask] = []
    var activeDays: Int { days.filter { $0.totals.totalTokens > 0 }.count }
    var total: UsageTotals { days.reduce(into: UsageTotals()) { $0.add($1.totals) } }
    var busiestDay: CodexUsageBucket? { days.filter { $0.totals.totalTokens > 0 }.max { $0.totals.totalTokens < $1.totals.totalTokens } }
    var streak: Int {
        var count = 0
        for day in days.reversed() {
            if day.totals.totalTokens > 0 { count += 1 }
            else if count > 0 || day.id != days.last?.id { break }
        }
        return count
    }
}

/// Queue confined by CodexUsageBackend. Keeps counters and metadata only, never conversation text.
final class CodexLogStore {
    struct Record {
        let key: String
        let session: String
        let modern: Bool
        let usage: UsageRecord
        let project: String
        let turn: Date?
    }
    private struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var discarding = false
        var inode: UInt64 = 0
        var modified = Date.distantPast
        var prefix = Data()
        var session: String
        var model = "codex"
        var project = ""
        var total: [Int]?
        var epoch = ""
        var modern = false
        var records: [String: Record] = [:]
        var task: CodexLiveTask?
        var plan: (String, Date)?
    }
    private var cursors: [URL: Cursor] = [:]
    private var discovered: [URL] = []
    private var discoveredAt = Date.distantPast
    private var cached: UsageSnapshot?
    private var cachedAt = Date.distantPast
    private var nextRecordDate: Date?
    private var cachedCalendar: Calendar?
    private(set) var bytesRead: UInt64 = 0
    private(set) var recordsParsed = 0
    let roots: [URL]
    private let price: (UsageRecord) -> Double?
    private let iso = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(roots: [URL], price: @escaping (UsageRecord) -> Double? = {
        ModelPricing.cost(model: $0.model, inputTokens: $0.uncachedInputTokens,
                          outputTokens: $0.outputTokens, cacheReadTokens: $0.cacheReadTokens,
                          cacheWriteTokens: $0.cacheWriteTokens)
    }) {
        self.roots = roots
        self.price = price
    }

    static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return ["sessions", "archived_sessions"].map { base.appendingPathComponent($0) }
    }

    func snapshot(now: Date, calendar: Calendar = .current, rediscover: Bool = false) -> UsageSnapshot {
        let start = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now))!
        var changed = false
        var readFailed = false
        if rediscover || now.timeIntervalSince(discoveredAt) >= 2 || discoveredAt == .distantPast {
            discoveredAt = now
            var files = Set<URL>()
            for root in roots {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], errorHandler: { _, _ in
                    readFailed = true
                    return true
                })
                if enumerator == nil { readFailed = true }
                while let file = enumerator?.nextObject() as? URL {
                    guard file.pathExtension == "jsonl" else { continue }
                    let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if modified == nil || modified! >= start { files.insert(file.standardizedFileURL.resolvingSymlinksInPath()) }
                }
            }
            discovered = files.sorted { $0.path < $1.path }
            if !readFailed {
                for file in Array(cursors.keys) where !files.contains(file) {
                    cursors.removeValue(forKey: file)
                    changed = true
                }
            }
        }
        for file in discovered {
            do { if try read(file, cutoff: start) { changed = true } }
            catch { readFailed = true }
        }
        if !changed, !rediscover, let cached, cachedCalendar == calendar,
           calendar.isDate(cachedAt, inSameDayAs: now), now.timeIntervalSince(cachedAt) < 60,
           nextRecordDate.map({ now < $0 }) ?? true, !readFailed { return cached }

        // ponytail: O(n) aggregation only after changes or once a minute; add bucket deltas if profiling warrants it.
        var firstModern: [String: Date] = [:]
        for cursor in cursors.values {
            for record in cursor.records.values where record.modern {
                firstModern[record.session] = min(firstModern[record.session] ?? .distantFuture, record.usage.timestamp)
            }
        }
        var unique: [String: Record] = [:]
        for file in cursors.keys.sorted(by: { $0.path < $1.path }) {
            var cursor = cursors[file]!
            cursor.records = cursor.records.filter { $0.value.usage.timestamp >= start }
            cursors[file] = cursor
            for record in cursor.records.values where record.modern || record.usage.timestamp < (firstModern[record.session] ?? .distantFuture) {
                unique[record.key] = record
            }
        }
        var tasks: [String: CodexLiveTask] = [:]
        for (file, cursor) in cursors where !file.pathComponents.contains("archived_sessions") {
            if let task = cursor.task, task.lastActivity >= start,
               tasks[task.id].map({ $0.lastActivity < task.lastActivity }) ?? true {
                tasks[task.id] = task
            }
        }
        nextRecordDate = unique.values.map(\.usage.timestamp).filter { $0 > now }.min()
        var result = aggregate(Array(unique.values), tasks: Array(tasks.values), now: now, calendar: calendar)
        result.plan = cursors.values.compactMap(\.plan).max { $0.1 < $1.1 }?.0
        if readFailed { result.localUsageError = String(localized: "Some Codex logs could not be read. Showing available data.") }
        else if discovered.isEmpty { result.localUsageError = String(localized: "No Codex usage logs found") }
        cached = result
        cachedAt = now
        cachedCalendar = calendar
        return result
    }

    private func read(_ file: URL, cutoff: Date) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        var cursor = cursors[file] ?? Cursor(session: file.deletingPathExtension().lastPathComponent)
        if cursor.offset == size, cursor.modified == modified, cursor.inode == inode { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: Int(min(size, UInt64(cursor.prefix.isEmpty ? 512 : cursor.prefix.count)))) ?? Data()
        if inode != cursor.inode || size < cursor.offset || (!cursor.prefix.isEmpty && prefix != cursor.prefix)
            || (size == cursor.offset && cursor.modified != modified) {
            cursor = Cursor(session: file.deletingPathExtension().lastPathComponent)
        }
        cursor.inode = inode
        cursor.modified = modified
        cursor.prefix = prefix
        try handle.seek(toOffset: cursor.offset)
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            bytesRead += UInt64(chunk.count)
            cursor.offset += UInt64(chunk.count)
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let newline = memchr(base.advanced(by: offset), 10, bytes.count - offset)
                    let end = newline.map { base.distance(to: $0) } ?? bytes.count
                    if !cursor.discarding {
                        if cursor.pending.count + end - offset > 1024 * 1024 {
                            cursor.pending.removeAll(keepingCapacity: true)
                            cursor.discarding = true
                        } else {
                            cursor.pending.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: end - offset)
                        }
                    }
                    if newline != nil {
                        if !cursor.discarding { parse(cursor.pending, cursor: &cursor, cutoff: cutoff) }
                        cursor.pending.removeAll(keepingCapacity: true)
                        cursor.discarding = false
                    }
                    offset = end + 1
                }
            }
        }
        // Accept a complete final JSON object; retain an incomplete write until the next poll.
        if !cursor.pending.isEmpty, !cursor.discarding,
           (try? JSONSerialization.jsonObject(with: cursor.pending)) != nil {
            parse(cursor.pending, cursor: &cursor, cutoff: cutoff)
            cursor.pending.removeAll(keepingCapacity: true)
        }
        cursors[file] = cursor
        return true
    }

    private func parse(_ data: Data, cursor: inout Cursor, cutoff: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["type"] as? String,
              ["session_meta", "turn_context", "token_usage_record", "event_msg"].contains(kind),
              let payload = object["payload"] as? [String: Any] else { return }
        recordsParsed += 1
        if kind == "session_meta" {
            if let session = payload["id"] as? String, !session.isEmpty { cursor.session = session }
            cursor.project = payload["cwd"] as? String ?? cursor.project
            return
        }
        if kind == "turn_context" {
            cursor.model = payload["model"] as? String ?? cursor.model
            cursor.project = payload["cwd"] as? String ?? cursor.project
            cursor.task?.model = cursor.model
            cursor.task?.project = cursor.project
            return
        }
        guard let stamp = object["timestamp"] as? String,
              let date = fractional.date(from: stamp) ?? iso.date(from: stamp) else { return }
        let event = payload["type"] as? String
        if kind == "event_msg", event == "task_started" {
            cursor.task = CodexLiveTask(id: cursor.session, started: date, lastActivity: date, model: cursor.model, project: cursor.project)
            return
        }
        if kind == "event_msg", event == "task_complete" || event == "turn_aborted" {
            cursor.task = nil
            return
        }
        var usage: [String: Any]?
        var key = ""
        if kind == "token_usage_record" {
            guard let recorded = payload["usage"] as? [String: Any] else { return }
            if !cursor.modern {
                cursor.modern = true
            }
            usage = recorded
            key = "response:\(cursor.session):\(payload["response_id"] as? String ?? stamp)"
        } else if event == "token_count" {
            if let limits = payload["rate_limits"] as? [String: Any], let plan = limits["plan_type"] as? String, !plan.isEmpty {
                cursor.plan = (plan, date)
            }
            guard !cursor.modern, let info = payload["info"] as? [String: Any] else { return }
            if let totalUsage = info["total_token_usage"] as? [String: Any] {
                let total = counters(totalUsage)
                let previous = cursor.total ?? [0, 0, 0, 0]
                guard total != cursor.total else { return }
                if total[0] + total[1] < previous[0] + previous[1] { cursor.epoch = stamp }
                cursor.total = total
                usage = info["last_token_usage"] as? [String: Any]
                if usage == nil {
                    let base = cursor.epoch == stamp ? [0, 0, 0, 0] : previous
                    usage = Dictionary(uniqueKeysWithValues: zip(["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens"], zip(total, base).map { max(0, $0 - $1) }))
                }
                key = "total:\(cursor.session):\(cursor.epoch):\(total)"
            } else {
                usage = info["last_token_usage"] as? [String: Any]
                key = "legacy:\(cursor.session):\(stamp)"
            }
        }
        guard let usage, date >= cutoff else { return }
        let counts = counters(usage)
        guard counts[0] + counts[1] + counts[3] > 0 else { return }
        let record = UsageRecord(timestamp: date, model: cursor.model,
                                 inputTokens: counts[0] + counts[3], outputTokens: counts[1],
                                 cacheReadTokens: min(counts[0], counts[2]), cacheWriteTokens: counts[3], dedupKey: key)
        cursor.records[key] = Record(key: key, session: cursor.session, modern: kind == "token_usage_record", usage: record,
                                     project: cursor.project, turn: cursor.task?.started)
        cursor.task?.lastActivity = date
    }

    private func counters(_ usage: [String: Any]) -> [Int] {
        ["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens"].map {
            max(0, min((usage[$0] as? NSNumber)?.intValue ?? 0, Int.max / 1000))
        }
    }

    func aggregate(_ records: [Record], tasks: [CodexLiveTask], now: Date, calendar: Calendar) -> UsageSnapshot {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<91).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var details = CodexUsageDetails()
        details.days = starts.map { CodexUsageBucket(start: $0) }
        var hour = today
        while hour < tomorrow {
            details.hours.append(CodexUsageBucket(start: hour))
            hour = calendar.date(byAdding: .hour, value: 1, to: hour)!
        }
        var models: [CodexUsagePeriod: [String: CodexUsageShare]] = [:]
        var projects: [CodexUsagePeriod: [String: CodexUsageShare]] = [:]
        var live = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var result = UsageSnapshot()
        for record in records where record.usage.timestamp >= starts[0] && record.usage.timestamp <= now {
            let usage = record.usage
            let cost = price(usage)
            let totals = UsageTotals(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                                     costUSD: cost ?? 0, hasUnpricedModel: cost == nil)
            let day = calendar.dateComponents([.day], from: starts[0], to: calendar.startOfDay(for: usage.timestamp)).day!
            details.days[day].totals.add(totals)
            if day == 90, let index = details.hours.lastIndex(where: { $0.start <= usage.timestamp }) {
                details.hours[index].totals.add(totals)
            }
            if usage.timestamp >= now.addingTimeInterval(-5 * 3600) { result.session.add(totals) }
            for period in CodexUsagePeriod.allCases where day > 90 - period.rawValue {
                details.periods[period, default: CodexPeriodUsage()].totals.add(totals)
                models[period, default: [:]][usage.model, default: CodexUsageShare(id: usage.model, name: usage.model)].totals.add(totals)
                let project = record.project.isEmpty ? "unknown-project" : record.project
                let name = record.project.isEmpty ? String(localized: "Unknown project") : URL(fileURLWithPath: project).lastPathComponent
                projects[period, default: [:]][project, default: CodexUsageShare(id: project, name: name)].totals.add(totals)
            }
            if let task = live[record.session], record.turn == task.started { live[record.session]?.totals.add(totals) }
        }
        for period in CodexUsagePeriod.allCases {
            var summary = details.periods[period] ?? CodexPeriodUsage()
            let byCost = !summary.totals.hasUnpricedModel
            func sorted(_ values: [String: CodexUsageShare]?) -> [CodexUsageShare] {
                (values.map { Array($0.values) } ?? []).sorted {
                    let a = $0.totals.weight(byCost: byCost), b = $1.totals.weight(byCost: byCost)
                    return a == b ? $0.id < $1.id : a > b
                }
            }
            summary.models = sorted(models[period])
            summary.projects = sorted(projects[period])
            details.periods[period] = summary
        }
        details.tasks = live.values.sorted { $0.started < $1.started }
        result.today = details.periods[.today]!.totals
        result.week = details.periods[.week]!.totals
        result.models = details.periods[.week]!.models.map { ModelUsage(model: $0.id, totals: $0.totals) }
        result.codexDetails = details
        result.lastUpdated = now
        return result
    }
}

/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should receive a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest
@testable import Atoll

final class JSONLUsageParserTests: XCTestCase {

    func testChunkBoundariesAndRecordSizeLimit() throws {
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let record = "{\"timestamp\":\"\(timestamp)\",\"model\":\"test\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3},\"padding\":\"%@\"}"
        // Exact chunk/record boundaries, UTF-8 across reads, oversized records,
        // and a final record without a newline must preserve the same totals.
        let sizes = [65_535, 65_536, 65_537, 1_048_576, 1_048_577, 3_000_000, 200]
        let lines = sizes.map { size -> String in
            let empty = String(format: record, "中")
            return String(format: record, "中" + String(repeating: "x", count: size - empty.utf8.count))
        }
        let file = try makeTempFile(content: lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = parseFile(file, now: now)
        XCTAssertEqual(snapshot.today.totalTokens, 50)
    }

    func testCodexPublishesQuotaBeforeReadingLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexQuotaStub.self]
        let client = CodexQuotaClient(session: URLSession(configuration: configuration), loadCredentials: { ("test", nil) })
        // Exercise protocol dispatch, as used by LLMUsageManager.
        let provider: UsageProvider = CodexUsageProvider(root: directory, quotaClient: client)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let update = expectation(description: "Quota published before log scan")
        let result = try await provider.fetchSnapshot(now: now) { snapshot in
            XCTAssertTrue(snapshot.isLocalUsageLoading)
            XCTAssertEqual(snapshot.sessionLimit?.used, 25)
            XCTAssertEqual(snapshot.weekLimit?.used, 60)
            update.fulfill()
            // If scanning happens before this awaited update, the final totals fail.
            let log = """
            {"type":"turn_context","payload":{"model":"test-model"}}
            {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":5}}}}
            """
            try! Data(log.utf8).write(to: directory.appendingPathComponent("usage.jsonl"))
        }
        await fulfillment(of: [update], timeout: 1)
        XCTAssertFalse(result.isLocalUsageLoading)
        XCTAssertEqual(result.today.totalTokens, 25)
        XCTAssertEqual(result.models.first?.model, "test-model")
        XCTAssertEqual(result.sessionLimit?.used, 25)
        XCTAssertNil(result.localUsageError)

        let missing = CodexUsageProvider(root: directory.appendingPathComponent("missing"), quotaClient: client)
        let quotaOnly = try await missing.fetchSnapshot(now: now)
        XCTAssertFalse(quotaOnly.isLocalUsageLoading)
        XCTAssertEqual(quotaOnly.sessionLimit?.used, 25)
        XCTAssertNotNil(quotaOnly.localUsageError)

        let offlineClient = CodexQuotaClient(loadCredentials: { nil })
        XCTAssertEqual(offlineClient.session.configuration.timeoutIntervalForResource, 20)
        let offline = try await CodexUsageProvider(root: directory, quotaClient: offlineClient).fetchSnapshot(now: now)
        XCTAssertNil(offline.sessionLimit)
        XCTAssertEqual(offline.today.totalTokens, 25)
    }

    private func makeTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let file = tempDir.appendingPathComponent("test_\(UUID().uuidString).jsonl")
        try content.data(using: .utf8)!.write(to: file)
        return file
    }

    private func parseFile(_ file: URL, now: Date) -> UsageSnapshot {
        JSONLUsageParser.aggregate(files: [file], now: now)
    }

    func testParseValidJSONLRecords() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts1 = iso.string(from: now.addingTimeInterval(-3600))
        let ts2 = iso.string(from: now.addingTimeInterval(-7200))

        let content = """
        {"timestamp": "\(ts1)", "message": {"id": "msg1", "model": "claude-3-opus", "usage": {"input_tokens": 100, "output_tokens": 50}}}
        {"timestamp": "\(ts2)", "message": {"id": "msg2", "model": "claude-3-sonnet", "usage": {"input_tokens": 200, "output_tokens": 100}}}
        """

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        XCTAssertEqual(snapshot.session.inputTokens, 300)
        XCTAssertEqual(snapshot.session.outputTokens, 150)
        XCTAssertEqual(snapshot.models.count, 2)
    }

    func testParseDeduplicatesByMessageId() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-3600))

        let content = """
        {"timestamp": "\(ts)", "message": {"id": "msg1", "model": "claude-3-opus", "usage": {"input_tokens": 100, "output_tokens": 50}}}
        {"timestamp": "\(ts)", "message": {"id": "msg1", "model": "claude-3-opus", "usage": {"input_tokens": 100, "output_tokens": 50}}}
        """

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        XCTAssertEqual(snapshot.session.inputTokens, 100)
        XCTAssertEqual(snapshot.session.outputTokens, 50)
        XCTAssertEqual(snapshot.models.count, 1)
    }

    func testRejectsOversizedUnterminatedRecord() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-3600))

        // Create a valid record followed by a valid JSON record padded
        // beyond the size limit (with a large dummy field), then a newline
        // and another valid record. The oversized record should be
        // excluded; parsing should resume and process the following record.
        let validRecord = "{\"timestamp\": \"\(ts)\", \"message\": {\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {\"input_tokens\": 100, \"output_tokens\": 50}}}"
        let padding = String(repeating: "x", count: 1024 * 1024 + 100)
        let oversizedRecord = "{\"timestamp\": \"\(ts)\", \"message\": {\"id\": \"msgOversized\", \"model\": \"claude-3-opus\", \"usage\": {\"input_tokens\": 100, \"output_tokens\": 50}}, \"padding\": \"\(padding)\"}"
        let validRecord2 = "{\"timestamp\": \"\(ts)\", \"message\": {\"id\": \"msg2\", \"model\": \"claude-3-sonnet\", \"usage\": {\"input_tokens\": 200, \"output_tokens\": 100}}}"
        let content = validRecord + "\n" + oversizedRecord + "\n" + validRecord2

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        // msg1 and msg2 should be parsed; the oversized record should be discarded entirely.
        XCTAssertEqual(snapshot.session.inputTokens, 300)
        XCTAssertEqual(snapshot.session.outputTokens, 150)
        XCTAssertEqual(snapshot.models.count, 2)
    }

    func testParsesAllowedSizeUnterminatedFinalRecord() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-3600))

        // Create a valid record followed by an allowed-size final line without newline
        let validRecord = "{\"timestamp\": \"\(ts)\", \"message\": {\"id\": \"msg1\", \"model\": \"claude-3-opus\", \"usage\": {\"input_tokens\": 100, \"output_tokens\": 50}}}"
        let finalLine = "{\"timestamp\": \"\(ts)\", \"message\": {\"id\": \"msg2\", \"model\": \"claude-3-sonnet\", \"usage\": {\"input_tokens\": 200, \"output_tokens\": 100}}}"
        let content = validRecord + "\n" + finalLine // No trailing newline

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        // Both records should be parsed
        XCTAssertEqual(snapshot.session.inputTokens, 300)
        XCTAssertEqual(snapshot.session.outputTokens, 150)
        XCTAssertEqual(snapshot.models.count, 2)
    }

    func testSkipsRecordsOutsideWeekWindow() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldTs = iso.string(from: now.addingTimeInterval(-8 * 86400)) // 8 days ago, outside week
        let recentTs = iso.string(from: now.addingTimeInterval(-3600))

        let content = """
        {"timestamp": "\(oldTs)", "message": {"id": "msg1", "model": "claude-3-opus", "usage": {"input_tokens": 100, "output_tokens": 50}}}
        {"timestamp": "\(recentTs)", "message": {"id": "msg2", "model": "claude-3-sonnet", "usage": {"input_tokens": 200, "output_tokens": 100}}}
        """

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        // Only the recent record should be counted
        XCTAssertEqual(snapshot.week.inputTokens, 200)
        XCTAssertEqual(snapshot.week.outputTokens, 100)
    }

    func testParseCodexTokenCountFormat() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-3600))

        let content = """
        {"type": "event_msg", "timestamp": "\(ts)", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 500, "output_tokens": 250}}}}
        """

        let file = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let snapshot = parseFile(file, now: now)

        XCTAssertEqual(snapshot.session.inputTokens, 500)
        XCTAssertEqual(snapshot.session.outputTokens, 250)
        XCTAssertTrue(snapshot.models.contains { $0.model == "codex" })
    }
}

private final class CodexQuotaStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"rate_limit":{"primary_window":{"used_percent":25},"secondary_window":{"used_percent":60}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import Foundation
import Testing
@testable import DingLaterCore

struct InboxTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DINGLATER_SAMPLE_DB"] != nil))
    func readableSourceBaseline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DINGLATER_SAMPLE_DB"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = try Inbox(directory: dir, testingKey: Data(repeating: 42, count: 32))
        let baseline = try await inbox.sync(source: URL(fileURLWithPath: path))
        #expect(baseline.baseline)
        #expect(baseline.added == 0)
        let rows = try await inbox.items()
        #expect(rows.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DINGLATER_LIVE_DB"] != nil))
    func liveEncryptedSourceReads() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DINGLATER_LIVE_DB"])
        let url = URL(fileURLWithPath: path)
        #expect(DingTalkKey.isEncrypted(url))
        let db = try SQLite(url, readOnly: true)
        let count = Int(try db.query("SELECT count(*) AS n FROM tbmsg_000").first?["n"] ?? "") ?? 0
        #expect(count >= 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = try Inbox(directory: dir, testingKey: Data(repeating: 42, count: 32))
        let latest = try await inbox.latestMessageDate(in: url)
        #expect(latest != nil)
    }

    @Test func mentionNamesAndGroupTitlesAreResolved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("live.db")
        let live = try SQLite(file, readOnly: false)
        try live.execute("PRAGMA journal_mode=WAL")
        let ddl = "(primaryKey INTEGER PRIMARY KEY, cid TEXT, mid INTEGER, senderId INTEGER, createdAt INTEGER, contentType INTEGER, content TEXT, recallStatus INTEGER, atIds TEXT)"
        for table in Inbox.tables { try live.execute("CREATE TABLE \(table)\(ddl)") }
        try live.execute("CREATE TABLE tbconversation(cid TEXT PRIMARY KEY, title TEXT, type INTEGER)")
        try live.execute("CREATE TABLE tbuser_profile_v2(uid TEXT PRIMARY KEY, realName TEXT, nick TEXT, alias TEXT)")
        try live.execute("INSERT INTO tbconversation VALUES('group1','测试群',2)")
        try live.execute("INSERT INTO tbuser_profile_v2 VALUES('100000001','','成员甲','')")

        let local = dir.appendingPathComponent("local")
        let inbox = try Inbox(directory: local, testingKey: Data(repeating: 3, count: 32))
        #expect(try await inbox.sync(source: file).baseline)

        try live.execute("""
            INSERT INTO tbmsg_000(cid,mid,senderId,createdAt,contentType,content,recallStatus,atIds)
            VALUES('group1',1,999,1800000000000,1,?,0,?)
            """, [#"{"contentType":1,"text":"@100000001 你好"}"#, #"{"100000001":"成员甲"}"#])
        #expect(try await inbox.sync(source: file).added == 1)

        let items = try await inbox.items()
        #expect(items.count == 1)
        #expect(items.first?.message.conversation == "测试群")
        #expect(items.first?.message.text == "@成员甲 你好")
    }

    @Test func testBaselineBatchReplayReminderAndRollback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dingtalk_decrypted.db")
        let live = try SQLite(file, readOnly: false)
        try live.execute("PRAGMA journal_mode=WAL")
        try live.execute("PRAGMA wal_autocheckpoint=0")
        let ddl = "(primaryKey INTEGER PRIMARY KEY, cid TEXT, mid INTEGER, senderId INTEGER, createdAt INTEGER, contentType INTEGER, content TEXT, recallStatus INTEGER)"
        for table in Inbox.tables { try live.execute("CREATE TABLE \(table)\(ddl)") }
        #expect(SourceDiscovery.find(in: [dir])?.standardizedFileURL.path == file.standardizedFileURL.path)
        func insert(_ table: String, _ mid: Int, _ body: String, recalled: Int = 0) throws {
            try live.execute("INSERT INTO \(table)(cid,mid,senderId,createdAt,contentType,content,recallStatus) VALUES('test',?,1,1800000000000,1,?,?)",
                             [String(mid), body, String(recalled)])
        }
        try insert("tbmsg_000", 99, "historical")
        let local = dir.appendingPathComponent("local")
        let key = Data(repeating: 17, count: 32)
        let first = try Inbox(directory: local, testingKey: key)
        let baseline = try await first.sync(source: file)
        #expect(baseline.baseline)
        for i in 1...10 {
            try insert(i < 8 ? "tbmsg_000" : "tbmsg_127", i, i <= 4 ? "！！！" : "synthetic message \(i)")
        }
        try insert("tbmsg_127", 10, "replay")
        try insert("tbmsg_127", 111, "recalled", recalled: 1)
        let page = try await first.sync(source: file, batchSize: 5)
        #expect(page.added == 5)
        #expect(page.remaining)
        let reopened = try Inbox(directory: local, testingKey: key)
        while try await reopened.sync(source: file, batchSize: 5).remaining {}
        let latest = try await reopened.latestMessageDate(in: file)
        #expect(latest?.timeIntervalSince1970 == 1800000000)
        let replay = try await reopened.sync(source: file)
        #expect(replay.added == 0)
        let items = try await reopened.items()
        #expect(items.count == 10)
        #expect(Set(items.map(\.id)).count == 10)
        #expect(items.filter { $0.message.text == "！！！" }.count == 4)
        #expect(!items.contains { ["historical", "replay", "recalled"].contains($0.message.text) })
        let id = try #require(items.first?.id)
        let due = Date().addingTimeInterval(900)
        try await reopened.move(id, to: .later, due: due)
        let snoozed = try await reopened.items()
        #expect(snoozed.first { $0.id == id }?.bucket == .later)
        let woke = try await reopened.wakeDue(at: due.addingTimeInterval(1))
        #expect(woke)
        try await reopened.move(id, to: .done)
        let done = try await reopened.items()
        #expect(done.first { $0.id == id }?.bucket == .done)
        try live.execute("DELETE FROM tbmsg_127")
        do {
            _ = try await reopened.sync(source: file)
            Issue.record("An older shard must not rewind the cursor")
        } catch { #expect(error.localizedDescription.contains("旧")) }
        let localDB = try SQLite(local.appendingPathComponent("inbox.sqlite"), readOnly: true)
        let boxes = try localDB.query("SELECT box FROM inbox")
        #expect(boxes.allSatisfy { Data(base64Encoded: $0["box"] ?? "") != nil })
        let wrongKey = try Inbox(directory: local, testingKey: Data(repeating: 18, count: 32))
        do {
            _ = try await wrongKey.items()
            Issue.record("Messages must require the original key")
        } catch {}
        try await reopened.completePending()
        let completed = try await reopened.items()
        #expect(completed.allSatisfy { $0.bucket == .done })
        let expired = try await reopened.expire(before: .distantFuture)
        #expect(expired.count == 10)
        let remaining = try await reopened.items()
        #expect(remaining.isEmpty)
    }
}


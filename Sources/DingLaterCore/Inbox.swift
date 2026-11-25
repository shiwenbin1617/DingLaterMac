import CryptoKit
import Foundation

public enum Bucket: String, CaseIterable, Sendable {
    case pending, later, done
    public var title: String {
        switch self { case .pending: return "待处理"; case .later: return "稍后提醒"; case .done: return "已处理" }
    }
}

public struct Message: Codable, Sendable {
    public let conversation: String
    public let sender: String
    public let text: String
    public let timestamp: Double
    public let conversationID: String?

    public init(conversation: String, sender: String, text: String, timestamp: Double, conversationID: String? = nil) {
        self.conversation = conversation
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.conversationID = conversationID
    }
}

public struct Item: Identifiable, Sendable {
    public let id: String
    public let message: Message
    public let bucket: Bucket
    public let due: Date?

    public var conversationKey: String { message.conversationID ?? message.conversation }
}

public struct SyncResult: Sendable {
    public let baseline: Bool
    public let added: Int
    public let remaining: Bool
}

public actor Inbox {
    let db: SQLite
    let key: SymmetricKey
    private let indexKey: SymmetricKey
    static let tables = (0..<128).map { String(format: "tbmsg_%03d", $0) }

    private var userCache: [String: String] = [:]
    private var mentionNameCache: [String: String] = [:]
    private var conversationCache: [String: String] = [:]
    private var repairedSources: Set<String> = []

    static func validateColumns(in source: SQLite) throws {
        for table in tables {
            try source.execute("SELECT primaryKey, cid, mid, senderId, createdAt, contentType, content, recallStatus FROM \(table) LIMIT 0")
        }
    }

    public init(directory: URL, testingKey: Data? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("inbox.sqlite")
        let database = try SQLite(file, readOnly: false)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("CREATE TABLE IF NOT EXISTS inbox(id TEXT PRIMARY KEY, box TEXT NOT NULL, state TEXT NOT NULL, due REAL, ts REAL NOT NULL)")
        try database.execute("CREATE INDEX IF NOT EXISTS inbox_state ON inbox(state, due)")
        try database.execute("CREATE TABLE IF NOT EXISTS progress(source TEXT, shard INTEGER, position INTEGER NOT NULL, PRIMARY KEY(source, shard))")
        let initialized = try database.query("SELECT 1 FROM progress LIMIT 1").first != nil
        let loaded = try testingKey.map { SymmetricKey(data: $0) } ?? Secrets.loadKey(allowCreation: !initialized)
        db = database
        key = loaded
        indexKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: loaded, salt: Data(), info: Data("index-v1".utf8), outputByteCount: 32)
    }

    private func fingerprint(_ parts: [String]) throws -> String {
        let bytes = try JSONEncoder().encode(parts)
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: indexKey)).base64EncodedString()
    }

    // MARK: - Display names

    /// The account's own uid appears in every one-to-one conversation cid
    /// (`peer:self`), so the most frequent component is the current user.
    static func detectSelfUID(in origin: SQLite) -> String? {
        guard let rows = try? origin.query("SELECT cid FROM tbconversation WHERE cid LIKE '%:%'") else { return nil }
        var counts: [String: Int] = [:]
        for row in rows {
            for part in (row["cid"] ?? "").split(separator: ":") {
                counts[String(part), default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private func userDisplay(_ uid: String, origin: SQLite, selfUID: String?) throws -> String {
        if uid.isEmpty { return "" }
        if uid == selfUID { return "我" }
        if let cached = userCache[uid] { return cached }
        var name: String?
        if let profile = try? origin.query("SELECT realName,nick,alias FROM tbuser_profile_v2 WHERE uid=? LIMIT 1", [uid]).first {
            name = [profile["realName"], profile["nick"], profile["alias"]]
                .compactMap { $0 }.first { !$0.isEmpty }
        }
        let value = name ?? "未知成员"
        userCache[uid] = value
        return value
    }

    private func userName(_ uid: String, origin: SQLite) -> String {
        if let cached = mentionNameCache[uid] { return cached }
        var name: String?
        if let profile = try? origin.query("SELECT realName,nick,alias FROM tbuser_profile_v2 WHERE uid=? LIMIT 1", [uid]).first {
            name = [profile["realName"], profile["nick"], profile["alias"]]
                .compactMap { $0 }.first { !$0.isEmpty }
        }
        let value = name ?? "未知成员"
        mentionNameCache[uid] = value
        return value
    }

    /// Rewrites DingTalk's `@<uid>` mentions using the per-message name map
    /// (`atIds`) or, failing that, the profile table.
    private func resolveMentions(_ text: String, names: [String: String], origin: SQLite) -> String {
        guard text.contains("@"), let regex = try? NSRegularExpression(pattern: "@(\\d{4,})") else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            let uid = source.substring(with: match.range(at: 1))
            var name = names[uid]
            if name == nil || name!.isEmpty {
                let resolved = userName(uid, origin: origin)
                if resolved != "未知成员" { name = resolved }
            }
            guard let name, !name.isEmpty else { continue }
            let range = match.range
            output += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            output += "@" + name
            cursor = range.location + range.length
        }
        guard cursor > 0 else { return text }
        return output + source.substring(from: cursor)
    }

    private func conversationTitle(cid: String, origin: SQLite, selfUID: String?) throws -> String {
        if let cached = conversationCache[cid] { return cached }
        var title: String?
        var type: String?
        if let row = try? origin.query("SELECT title,type FROM tbconversation WHERE cid=? LIMIT 1", [cid]).first {
            title = row["title"]
            type = row["type"]
        }
        let parts = cid.split(separator: ":").map(String.init)
        let direct = type == "1" || (parts.count == 2 && type != "2")
        var result: String
        if direct, parts.count == 2 {
            let peer = parts[0] == selfUID ? parts[1] : parts[0]
            let name = try userDisplay(peer, origin: origin, selfUID: selfUID)
            if name != "未知成员" {
                result = name
            } else if let title, !title.isEmpty, title != cid, !title.allSatisfy({ $0.isNumber }) {
                result = title
            } else {
                result = "未知联系人"
            }
        } else if let title, !title.isEmpty {
            result = title
        } else {
            result = parts.count == 2 ? "未知联系人" : "群聊"
        }
        conversationCache[cid] = result
        return result
    }

    /// Best-effort upgrade of display names already stored by older builds,
    /// which kept the raw cid or uid in the conversation/sender fields.
    private func legacyDisplay(_ value: String, origin: SQLite, selfUID: String?, sender: Bool) throws -> String {
        if value.isEmpty { return value }
        if value.contains(":") { return try conversationTitle(cid: value, origin: origin, selfUID: selfUID) }
        let numeric = value.allSatisfy { $0.isNumber }
        guard numeric else { return value }
        if sender {
            let name = try userDisplay(value, origin: origin, selfUID: selfUID)
            return name == "未知成员" ? value : name
        }
        if let row = try? origin.query("SELECT title,type FROM tbconversation WHERE cid=? LIMIT 1", [value]).first,
           row["type"] == "2" {
            let title = row["title"] ?? ""
            return title.isEmpty ? "群聊" : title
        }
        let name = try userDisplay(value, origin: origin, selfUID: selfUID)
        return name == "未知成员" ? value : name
    }

    /// Older builds stored only the display value, so rebuild the cid that the
    /// conversation belongs to. This keeps legacy items in the same group as
    /// newly captured messages from the same person or group.
    private func inferCID(_ value: String, origin: SQLite, selfUID: String?) -> String? {
        if value.contains(":") { return value }
        guard value.allSatisfy({ $0.isNumber }) else { return nil }
        if let row = try? origin.query("SELECT cid FROM tbconversation WHERE cid=? LIMIT 1", [value]).first {
            return row["cid"]
        }
        if let selfUID {
            let candidates = [value + ":" + selfUID, selfUID + ":" + value]
            if let row = try? origin.query("SELECT cid FROM tbconversation WHERE cid IN (?,?) LIMIT 1", candidates).first {
                return row["cid"]
            }
        }
        return nil
    }

    private func repairNames(origin: SQLite, selfUID: String?) throws {
        let rows = try db.query("SELECT id, box FROM inbox")
        var updates: [(String, String)] = []
        for row in rows {
            guard let id = row["id"], let box = Data(base64Encoded: row["box"] ?? "") else { continue }
            guard let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: Data(id.utf8)),
                  let message = try? JSONDecoder().decode(Message.self, from: opened) else { continue }
            let conversation = try legacyDisplay(message.conversation, origin: origin, selfUID: selfUID, sender: false)
            let sender = message.sender == "我" ? "我"
                : ((try? legacyDisplay(message.sender, origin: origin, selfUID: selfUID, sender: true)) ?? message.sender)
            let conversationID = message.conversationID ?? inferCID(message.conversation, origin: origin, selfUID: selfUID)
            let text = resolveMentions(message.text, names: [:], origin: origin)
            guard conversation != message.conversation || sender != message.sender
                    || text != message.text || conversationID != message.conversationID else { continue }
            let updated = Message(conversation: conversation, sender: sender, text: text,
                                  timestamp: message.timestamp, conversationID: conversationID)
            guard let sealed = try? AES.GCM.seal(JSONEncoder().encode(updated), using: key, authenticating: Data(id.utf8)).combined else { continue }
            updates.append((id, sealed.base64EncodedString()))
        }
        guard !updates.isEmpty else { return }
        try db.transaction(write: true) {
            for (id, box) in updates { try db.execute("UPDATE inbox SET box=? WHERE id=?", [box, id]) }
        }
    }

    // MARK: - Reading

    public func latestMessageDate(in source: URL) throws -> Date? {
        let input = try SQLite(source, readOnly: true)
        let parts = Self.tables.map { "SELECT max(createdAt) AS ms FROM " + $0 }
        let query = "SELECT max(ms) AS latest FROM (" + parts.joined(separator: " UNION ALL ") + ")"
        guard let raw = try input.query(query).first?["latest"], let ms = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public func sync(source: URL, batchSize: Int = 500) throws -> SyncResult {
        let origin = try SQLite(source, readOnly: true)
        let sourceID = try fingerprint(["source", source.standardizedFileURL.path])
        let selfUID = Self.detectSelfUID(in: origin)
        if !repairedSources.contains(sourceID) {
            repairedSources.insert(sourceID)
            try repairNames(origin: origin, selfUID: selfUID)
        }
        let limit = max(1, min(batchSize, 2000))
        return try origin.transaction {
            let tableNames = Set(try origin.query("SELECT name FROM sqlite_schema WHERE type='table'").compactMap { $0["name"] })
            guard Set(Self.tables).isSubset(of: tableNames) else { throw InboxError("数据源缺少 V3 消息分表。") }
            let supportsAtIds = (try? origin.query("PRAGMA table_info(tbmsg_000)"))?
                .contains { $0["name"] == "atIds" } ?? false
            let atIdsSelect = supportsAtIds ? "atIds" : "NULL AS atIds"
            let maxima = try Self.tables.map { table in
                Int64(try origin.query("SELECT coalesce(max(primaryKey),0) AS n FROM \(table)").first?["n"] ?? "") ?? 0
            }
            return try db.transaction(write: true) {
                let cursorRows = try db.query("SELECT shard, position FROM progress WHERE source=? ORDER BY shard", [sourceID])
                if cursorRows.isEmpty {
                    try Self.validateColumns(in: origin)
                    for index in Self.tables.indices {
                        try db.execute("INSERT INTO progress VALUES (?,?,?)", [sourceID, String(index), String(maxima[index])])
                    }
                    return SyncResult(baseline: true, added: 0, remaining: false)
                }
                let positions = cursorRows.compactMap { Int64($0["position"] ?? "") }
                guard positions.count == Self.tables.count else { throw InboxError("本地读取进度不完整。") }
                guard !zip(maxima, positions).contains(where: { $0 < $1 }) else {
                    throw InboxError("数据源比上次读取的版本旧，或有分表被清理。已保留进度，请选择同一账号的新快照。")
                }

                var capacity = limit
                var added = 0
                var more = false
                for (i, table) in Self.tables.enumerated() where positions[i] < maxima[i] {
                    guard capacity > 0 else { more = true; break }
                    let rows = try origin.query("""
                        SELECT primaryKey, cid, mid, senderId, createdAt, contentType, content, recallStatus, \(atIdsSelect)
                        FROM \(table) WHERE primaryKey > ? ORDER BY primaryKey LIMIT ?
                        """, [String(positions[i]), String(capacity)])
                    guard let last = rows.last?["primaryKey"] else { throw InboxError("消息游标无法继续。") }
                    for row in rows where (row["recallStatus"] ?? "0") == "0" {
                        if try save(row, sourceID: sourceID, shard: table, origin: origin, tables: tableNames, selfUID: selfUID) { added += 1 }
                    }
                    try db.execute("UPDATE progress SET position=? WHERE source=? AND shard=?", [last, sourceID, String(i)])
                    capacity -= rows.count
                    if Int64(last) != maxima[i] { more = true }
                }
                return SyncResult(baseline: false, added: added, remaining: more)
            }
        }
    }

    private func save(_ row: Row, sourceID: String, shard: String, origin: SQLite,
                      tables: Set<String>, selfUID: String?) throws -> Bool {
        guard let cid = row["cid"], !cid.isEmpty, let pk = row["primaryKey"],
              let ms = Double(row["createdAt"] ?? "") else { throw InboxError("新消息缺少会话、主键或时间。") }
        let id: String
        if let mid = row["mid"], mid != "0", !mid.isEmpty {
            id = try fingerprint([sourceID, cid, "mid", mid])
        } else {
            id = try fingerprint([sourceID, cid, shard, pk])
        }
        if try !db.query("SELECT 1 FROM inbox WHERE id=?", [id]).isEmpty { return false }
        let title = try conversationTitle(cid: cid, origin: origin, selfUID: selfUID)
        let senderRaw = row["senderId"] ?? ""
        var sender = try userDisplay(senderRaw, origin: origin, selfUID: selfUID)
        if sender.isEmpty { sender = "未知成员" }
        let (rawText, mentionNames) = Self.parsedBody(row)
        let message = Message(conversation: title, sender: sender,
                              text: resolveMentions(rawText, names: mentionNames, origin: origin),
                              timestamp: ms / 1000, conversationID: cid)
        let box = try AES.GCM.seal(JSONEncoder().encode(message), using: key, authenticating: Data(id.utf8))
        guard let encrypted = box.combined else { throw InboxError("消息加密失败。") }
        try db.execute("INSERT INTO inbox(id,box,state,ts) VALUES(?,?,'pending',?)", [id, encrypted.base64EncodedString(), String(message.timestamp)])
        return true
    }

    private static func parsedBody(_ row: Row) -> (String, [String: String]) {
        let raw = row["content"] ?? ""
        var text: String?
        var names: [String: String] = [:]
        if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            for field in ["text", "title", "content", "fileName", "desc"] {
                if let value = obj[field] as? String, !value.isEmpty { text = value; break }
            }
            if let map = obj["atIds"] as? [String: String] {
                names.merge(map) { _, new in new }
            } else if let json = obj["atIds"] as? String,
                      let map = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] {
                names.merge(map) { _, new in new }
            }
        } else if !raw.isEmpty {
            text = raw
        }
        if let json = row["atIds"],
           let map = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] {
            names.merge(map) { _, new in new }
        }
        let fallback = "〔消息类型 \(row["contentType"] ?? "未知")〕"
        return (text ?? fallback, names)
    }

    public func wakeDue(at date: Date = Date()) throws -> Bool {
        try db.execute("UPDATE inbox SET state='pending', due=NULL WHERE state='later' AND due<=?", [String(date.timeIntervalSince1970)])
        return try db.query("SELECT changes() AS n").first?["n"] != "0"
    }

    public func expire(before cutoff: Date) throws -> [String] {
        let limit = [String(cutoff.timeIntervalSince1970)]
        return try db.transaction(write: true) {
            let ids = try db.query("SELECT id FROM inbox WHERE ts<?", limit).compactMap { $0["id"] }
            if !ids.isEmpty { try db.execute("DELETE FROM inbox WHERE ts<?", limit) }
            return ids
        }
    }

    public func completePending() throws {
        try db.execute("UPDATE inbox SET state='done',due=NULL WHERE state='pending'")
    }

    public func items() throws -> [Item] {
        try db.query("SELECT * FROM inbox ORDER BY ts DESC, id").map { row in
            guard let id = row["id"], let box = Data(base64Encoded: row["box"] ?? ""),
                  let bucket = Bucket(rawValue: row["state"] ?? "") else { throw InboxError("回复箱记录损坏。") }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: Data(id.utf8))
            let message = try JSONDecoder().decode(Message.self, from: data)
            let due = row["due"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            return Item(id: id, message: message, bucket: bucket, due: due)
        }
    }

    public func move(_ id: String, to bucket: Bucket, due: Date? = nil) throws {
        if bucket == .later {
            guard let due, due > Date() else { throw InboxError("请选择未来的提醒时间。") }
            try db.execute("UPDATE inbox SET state=?,due=? WHERE id=?", [bucket.rawValue, String(due.timeIntervalSince1970), id])
        } else {
            try db.execute("UPDATE inbox SET state=?,due=NULL WHERE id=?", [bucket.rawValue, id])
        }
    }
}

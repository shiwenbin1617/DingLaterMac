import DingTalkVFS
import Foundation
import SQLite3

public struct InboxError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

typealias Row = [String: String]

final class SQLite {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let encrypted = readOnly && DingTalkKey.isEncrypted(url)
        let result: Int32
        if encrypted {
            guard let key = DingTalkKey.load(), key.count == 16 else {
                throw InboxError("这是加密的钉钉实时数据库。请在「数据源与设置」中填写数据库密钥。")
            }
            dingtalk_vfs_register()
            key.withUnsafeBytes { dingtalk_vfs_set_key($0.bindMemory(to: UInt8.self).baseAddress) }
            result = url.path.withCString { path in
                "dingtalk".withCString { vfs in
                    sqlite3_open_v2(path, &db, flags, vfs)
                }
            }
        } else {
            result = url.path.withCString { path in
                sqlite3_open_v2(path, &db, flags, nil)
            }
        }
        guard result == SQLITE_OK, let opened = db else {
            sqlite3_close(db)
            throw InboxError(readOnly ? "无法打开所选 SQLite 文件。" : "无法打开回复箱。")
        }
        handle = opened
        sqlite3_busy_timeout(opened, 1500)
        if readOnly { try execute("PRAGMA query_only=ON") }
        try execute("PRAGMA trusted_schema=OFF")
    }

    deinit { sqlite3_close(handle) }

    private func error() -> InboxError {
        if sqlite3_errcode(handle) == SQLITE_NOTADB {
            return InboxError("所选文件不是标准 SQLite 数据库。请选择已可读取的消息快照。")
        }
        return InboxError(String(cString: sqlite3_errmsg(handle)))
    }

    @discardableResult
    func query(_ sql: String, _ values: [String] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error()
        }
        defer { sqlite3_finalize(stmt) }
        guard Int(sqlite3_bind_parameter_count(stmt)) == values.count else {
            throw InboxError("SQLite 参数数量不匹配。")
        }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        var result: [Row] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                var row = Row()
                for i in 0..<sqlite3_column_count(stmt) {
                    if let value = sqlite3_column_text(stmt, i) {
                        let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(stmt, i)))
                        row[String(cString: sqlite3_column_name(stmt, i))] = String(decoding: bytes, as: UTF8.self)
                    }
                }
                result.append(row)
            default: throw error()
            }
        }
    }

    func execute(_ sql: String, _ values: [String] = []) throws { _ = try query(sql, values) }

    func transaction<T>(write: Bool = false, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}


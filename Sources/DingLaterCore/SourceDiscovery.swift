import Foundation

public enum SourceDiscovery {
    /// Live DingTalk ArkDB files, newest first. These are read in place with the
    /// decrypting VFS, so the inbox reflects messages as they are committed.
    public static func liveDatabases() -> [URL] {
        let fm = FileManager.default
        let roots = ["DingTalkMac", "DingTalk"].compactMap {
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent($0, isDirectory: true)
        }
        var found: [(URL, Date)] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let url = entry.appendingPathComponent("DBFiles/dingtalk.db")
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append((url, date))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    public static func isSource(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        do {
            let db = try SQLite(url, readOnly: true)
            try db.transaction {
                let names = try db.query("SELECT name FROM sqlite_schema WHERE type='table'")
                guard Set(Inbox.tables).isSubset(of: Set(names.compactMap { $0["name"] })) else {
                    throw InboxError("数据源缺少 V3 消息分表。")
                }
                try Inbox.validateColumns(in: db)
            }
            return true
        } catch { return false }
    }

    /// First live database that can be decoded with the configured key.
    public static func findLive() -> URL? {
        liveDatabases().first { isSource($0) }?.standardizedFileURL
    }

    public static func find() -> URL? {
        if let live = findLive() { return live }
        let fm = FileManager.default
        let homeFolders = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        let appFolder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DingLaterMac/Sources", isDirectory: true)
        return find(in: homeFolders + [appFolder].compactMap { $0 })
    }

    static func find(in folders: [URL]) -> URL? {
        let names = ["dingtalk_decrypted.db", "dingtalk_decrypted.sqlite", "dingtalk.db"]
        for folder in folders {
            for base in [folder, folder.appendingPathComponent("DingLater", isDirectory: true)] {
                for name in names {
                    let url = base.appendingPathComponent(name)
                    if isSource(url) { return url.standardizedFileURL }
                }
            }
        }
        return nil
    }
}

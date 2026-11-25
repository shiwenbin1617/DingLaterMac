import Foundation

/// The 16-byte key for the live DingTalk ArkDB. It can come from the
/// `DINGLATER_DINGTALK_KEY` environment variable, a 0600 file in the app's
/// support folder, or the value stored from the settings window.
public enum DingTalkKey {
    /// First 16 bytes shared by every page-1 ciphertext of an ArkDB file
    /// (it is the AES-ECB ciphertext of "SQLite format 3\0").
    public static let magic: [UInt8] = [
        0x27, 0x30, 0xa9, 0x03, 0x2e, 0x85, 0xce, 0x79,
        0x28, 0x52, 0xc3, 0x21, 0x44, 0x86, 0xce, 0xea
    ]

    public static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DingLaterMac", isDirectory: true)
            .appendingPathComponent("dingtalk.key")
    }

    public static func isEncrypted(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return Array(head) == magic
    }

    /// Accepts 16 raw characters or 32 hex digits.
    public static func parse(_ raw: String) -> Data? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.utf8.count == 16 { return Data(value.utf8) }
        guard value.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }

    public static func load() -> Data? {
        if let raw = ProcessInfo.processInfo.environment["DINGLATER_DINGTALK_KEY"], let key = parse(raw) {
            return key
        }
        if let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8), let key = parse(text) {
            return key
        }
        if let raw = UserDefaults.standard.string(forKey: "dingtalkKey"), let key = parse(raw) {
            return key
        }
        return nil
    }

    public static var isConfigured: Bool { load() != nil }

    public static func save(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parse(value) != nil else {
            throw InboxError("密钥需要 16 个字符或 32 位十六进制。")
        }
        UserDefaults.standard.set(value, forKey: "dingtalkKey")
        guard let url = fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(value.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

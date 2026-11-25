import AppKit
import DingLaterCore
import SwiftUI
import UserNotifications
import ServiceManagement

struct ConversationGroup: Identifiable {
    let id: String
    let title: String
    let items: [Item]

    var latest: Item { items[items.count - 1] }
    var count: Int { items.count }
    var senders: [String] { Array(Set(items.map { $0.message.sender })).sorted() }
}

@MainActor
final class Model: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var items: [Item] = [] {
        didSet {
            let total = count(.pending)
            NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
        }
    }
    @Published var retention = UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 7
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var bucket = Bucket.pending
    @Published var selected: String?
    @Published var query = ""
    @Published var source = UserDefaults.standard.url(forKey: "source")
    @Published var paused = UserDefaults.standard.bool(forKey: "paused")
    @Published var pinned = false
    @Published var busy = false
    @Published var detecting = false
    @Published var discoveryNote: String?
    @Published var status = "尚未连接数据源"
    @Published var problem: String?
    @Published var lastCheck: Date?
    @Published var latestSourceMessage: Date?
    @Published var keyConfigured = DingTalkKey.isConfigured
    private var migratedToLive = false
    private var observedSource: URL?
    private var observedWrites: [Date?] = []
    @Published var showSettings = false
    weak var window: NSWindow?
    private var store: Inbox?
    private var loaded = false
    private var nextCleanup = Date.distantPast
    private var nextDiscovery = Date.distantPast
    private var loop: Task<Void, Never>?
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DingLaterMac", isDirectory: true)

    var conversations: [ConversationGroup] {
        let rows = items.filter {
            $0.bucket == bucket && (query.isEmpty || [$0.message.conversation, $0.message.sender, $0.message.text]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let grouped = Dictionary(grouping: rows, by: \.conversationKey)
        return grouped.map { key, values in
            let ordered = values.sorted { lhs, rhs in
                lhs.message.timestamp == rhs.message.timestamp ? lhs.id < rhs.id : lhs.message.timestamp < rhs.message.timestamp
            }
            return ConversationGroup(id: key, title: ordered.last!.message.conversation, items: ordered)
        }.sorted { $0.latest.message.timestamp > $1.latest.message.timestamp }
    }

    var currentConversation: ConversationGroup? {
        conversations.first { $0.id == selected } ?? conversations.first
    }

    func count(_ bucket: Bucket) -> Int { items.lazy.filter { $0.bucket == bucket }.count }
    var isLiveSource: Bool { source?.lastPathComponent == "dingtalk.db" }

    func saveDingTalkKey(_ value: String) {
        do {
            try DingTalkKey.save(value)
            keyConfigured = true
            problem = nil
            Task { await refresh(findSource: true) }
        } catch { problem = error.localizedDescription }
    }

    func start() {
        guard loop == nil else { return }
        UNUserNotificationCenter.current().delegate = self
        loop = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func choose() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择可读的钉钉 SQLite 数据源"
        panel.prompt = "连接"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await refresh(candidate: url) }
    }

    func pause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "paused")
        if paused { status = "已暂停收录" } else { Task { await refresh() } }
    }

    func setPinned() {
        pinned.toggle()
        window?.level = pinned ? .floating : .normal
    }

    func setLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch { problem = error.localizedDescription }
        }
    }

    func setRetention(_ days: Int) {
        retention = max(1, min(365, days))
        UserDefaults.standard.set(retention, forKey: "retentionDays")
        nextCleanup = .distantPast
        Task { await refresh() }
    }

    func completePending() {
        Task {
            guard let store else { return }
            do { try await store.completePending(); items = try await store.items() }
            catch { problem = error.localizedDescription }
        }
    }

    func refresh(candidate: URL? = nil, findSource: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var url = candidate ?? source
        let missing = url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if candidate == nil && (findSource || (missing && !paused && Date() >= nextDiscovery)) {
            nextDiscovery = Date().addingTimeInterval(60)
            detecting = true
            let found = await Task.detached(priority: .utility) { SourceDiscovery.find() }.value
            detecting = false
            if let found {
                url = found
                discoveryNote = "自动找到 " + found.lastPathComponent
            } else {
                discoveryNote = "常用位置未找到可读的钉钉消息库。"
            }
        }
        if candidate == nil, !migratedToLive, let current = url,
           ["dingtalk_decrypted.db", "dingtalk_decrypted.sqlite"].contains(current.lastPathComponent),
           DingTalkKey.isConfigured,
           let live = await Task.detached(priority: .utility, operation: { SourceDiscovery.findLive() }).value {
            migratedToLive = true
            url = live
            discoveryNote = "已切换到钉钉实时数据库"
        }
        guard url != nil || FileManager.default.fileExists(atPath: directory.appendingPathComponent("inbox.sqlite").path) else { return }
        do {
            if store == nil {
                let location = directory
                store = try await Task.detached { try Inbox(directory: location) }.value
            }
            guard let store else { return }
            let woke = try await store.wakeDue()
            var removed: [String] = []
            if nextCleanup <= Date() {
                removed = try await store.expire(before: Date().addingTimeInterval(-Double(retention) * 86400))
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: removed)
                nextCleanup = Date().addingTimeInterval(60)
            }
            if !loaded || woke || !removed.isEmpty { items = try await store.items(); loaded = true }
            guard let url, !paused || candidate != nil else { return }
            let result = try await store.sync(source: url)
            if url != source {
                source = url
                UserDefaults.standard.set(url, forKey: "source")
            }
            if candidate != nil {
                discoveryNote = nil
                paused = false
                UserDefaults.standard.set(false, forKey: "paused")
            }
            if result.added > 0 { items = try await store.items() }
            let files = [url, URL(fileURLWithPath: url.path + "-wal")]
            let writes = files.map { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            if observedSource != url || observedWrites != writes || result.added > 0 {
                latestSourceMessage = try await store.latestMessageDate(in: url)
                observedWrites = writes
                observedSource = url
            }
            lastCheck = Date()
            if result.baseline { status = "已建立文件基线" }
            else if result.remaining { status = "正在补收消息…" }
            else { status = "监看本地文件" }
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    func move(_ item: Item, _ bucket: Bucket, due: Date? = nil) {
        Task {
            guard let store else { return }
            do {
                if let due, due.timeIntervalSince1970 >= item.message.timestamp + Double(retention) * 86400 {
                    throw InboxError("提醒时间超出了消息保留期限，请选更早的时间。")
                }
                try await store.move(item.id, to: bucket, due: due)
                items = try await store.items()
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: [item.id])
                center.removeDeliveredNotifications(withIdentifiers: [item.id])
                if let due, bucket == .later {
                    if try await center.requestAuthorization(options: [.alert, .sound]) {
                        let content = UNMutableNotificationContent()
                        content.title = "DingLater · 回复提醒"
                        content.body = "有一条稍后提醒已到期。"
                        content.sound = .default
                        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
                        try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
                    }
                }
            } catch { problem = error.localizedDescription }
        }
    }

    func move(_ group: ConversationGroup, to bucket: Bucket, due: Date? = nil) {
        Task {
            guard let store else { return }
            do {
                if let due, due.timeIntervalSince1970 >= group.latest.message.timestamp + Double(retention) * 86400 {
                    throw InboxError("提醒时间超出了消息保留期限，请选更早的时间。")
                }
                for item in group.items { try await store.move(item.id, to: bucket, due: due) }
                items = try await store.items()
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: [group.id])
                center.removeDeliveredNotifications(withIdentifiers: [group.id])
                if let due, bucket == .later {
                    if try await center.requestAuthorization(options: [.alert, .sound]) {
                        let content = UNMutableNotificationContent()
                        content.title = "DingLater · 回复提醒"
                        content.body = "「\(group.title)」有一条稍后提醒已到期。"
                        content.sound = .default
                        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
                        try await center.add(UNNotificationRequest(identifier: group.id, content: content, trigger: trigger))
                    }
                }
            } catch { problem = error.localizedDescription }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await refresh()
            bucket = .pending
            query = ""
            selected = response.notification.request.identifier
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}


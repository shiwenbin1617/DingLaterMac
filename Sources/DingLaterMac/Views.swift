import AppKit
import DingLaterCore
import SwiftUI

let jade = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
        return NSColor(srgbRed: 0.35, green: 0.78, blue: 0.67, alpha: 1)
    }
    return NSColor(srgbRed: 0.07, green: 0.43, blue: 0.37, alpha: 1)
})

/// Solid fill for prominent buttons: deep enough that white labels stay legible,
/// unlike the bright accent used for icons and selection.
let jadeSolid = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
        return NSColor(srgbRed: 0.04, green: 0.46, blue: 0.39, alpha: 1)
    }
    return NSColor(srgbRed: 0.05, green: 0.41, blue: 0.33, alpha: 1)
})

extension Bucket {
    var icon: String {
        switch self { case .pending: return "tray"; case .later: return "clock"; case .done: return "checkmark.circle" }
    }
}

struct Brand: View {
    var size: CGFloat = 36
    private static let mascot = Bundle.main.url(forResource: "Koala", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        Group {
            if let mascot = Self.mascot { Image(nsImage: mascot).resizable().interpolation(.high).scaledToFit() }
            else { Text("🐨").font(.system(size: size * 0.75)) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WindowReader: NSViewRepresentable {
    let capture: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { capture(window) } }
    }
}

struct InboxView: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    @State private var customReminder: ConversationGroup?
    @State private var confirmBatch = false
    private var palette: InboxPalette { InboxPalette(scheme) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            Divider()
            messageList.frame(minWidth: 238, idealWidth: 282, maxWidth: 330)
            Divider()
            detail.frame(minWidth: 332, maxWidth: .infinity, maxHeight: .infinity).background(palette.reader)
        }
        .frame(minWidth: 800, minHeight: 460)
        .background(WindowReader { model.window = $0 })
        .tint(jadeSolid)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(item: $customReminder) { group in
            ReminderView { date in model.move(group, to: .later, due: date) }
        }
        .confirmationDialog("将所有待处理消息标为已处理？", isPresented: $confirmBatch) {
            Button("全部标为已处理") { model.completePending() }
            Button("取消", role: .cancel) {}
        } message: { Text("包括当前搜索结果之外的待处理消息。") }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy || model.paused || model.source == nil).help("立即检查新消息")
                Button { model.setPinned() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin") }
                    .help("置顶回复箱窗口").keyboardShortcut("t", modifiers: [.command, .option])
            }
        }
        .onAppear { model.start() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Brand(size: 42)
                Text("DingLater").font(.system(size: 17, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 16).padding(.top, 23).padding(.bottom, 28)
            ForEach(Bucket.allCases, id: \.self) { bucket in
                Button {
                    model.bucket = bucket
                    model.selected = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: bucket.icon).font(.system(size: 15, weight: .medium)).frame(width: 18)
                        Text(bucket.title)
                        Spacer()
                        Text("\(model.count(bucket))").font(.caption.monospacedDigit())
                    }.padding(.horizontal, 10).frame(height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.bucket == bucket ? palette.highlight : .secondary)
                .background {
                    if model.bucket == bucket {
                        Color.clear.inboxGlass(in: Capsule(), tint: jade.opacity(0.14))
                    }
                }.padding(.horizontal, 9).padding(.bottom, 4)
            }
            Spacer()
            Divider().padding(.horizontal, 12)
            Button { model.showSettings = true } label: {
                HStack {
                    Circle().fill(model.problem != nil ? Color.orange : model.source == nil || model.paused ? .secondary : jade)
                        .frame(width: 7, height: 7)
                    Text(model.detecting ? "正在查找数据源…" : model.problem != nil ? "数据源需要检查" : model.paused ? "已暂停收录" : model.status)
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Image(systemName: "gearshape")
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).help("数据源与设置")
        }.frame(maxHeight: .infinity).background(palette.sidebar)
    }

    private var messageList: some View {
        let rows = model.conversations
        let selection = rows.first(where: { $0.id == model.selected })?.id ?? rows.first?.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.bucket.title).font(.title2.weight(.semibold))
                Spacer()
                Text("\(rows.count) 个会话").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if model.bucket == .pending && model.count(.pending) > 0 {
                    Menu { Button("全部标为已处理…") { confirmBatch = true } } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuStyle(.borderlessButton).fixedSize().help("批量处理")
                }
            }.padding(.horizontal, 16).padding(.top, 22)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索消息或联系人", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(8).background(palette.searchField, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 14).padding(.vertical, 14)
            Divider()
            if rows.isEmpty {
                Text(model.query.isEmpty ? "暂无\(model.bucket.title)消息" : "没有匹配的消息")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 34)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(rows) { group in
                            Button { model.selected = group.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(group.title).font(.headline).lineLimit(1)
                                        Spacer(minLength: 6)
                                        if group.count > 1 {
                                            Text("\(group.count)")
                                                .font(.caption2.monospacedDigit())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(jade.opacity(0.16), in: Capsule())
                                        }
                                        Text(Date(timeIntervalSince1970: group.latest.message.timestamp), style: .time)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(preview(group)).font(.callout).foregroundStyle(.secondary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    if let due = group.items.compactMap(\.due).min() {
                                        Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                            .font(.caption).foregroundStyle(jade)
                                    }
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(selection == group.id ? jade.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(6)
                }
            }
        }.background(palette.list)
    }

    private func preview(_ group: ConversationGroup) -> String {
        let item = group.latest
        let prefix = item.message.sender != group.title && !item.message.sender.isEmpty ? "\(item.message.sender)：" : ""
        return prefix + item.message.text
    }

    @ViewBuilder private var detail: some View {
        if let group = model.currentConversation {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.bucket.title, systemImage: model.bucket.icon).font(.caption.weight(.medium)).foregroundStyle(jade)
                    Text(group.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack {
                        if !group.senders.isEmpty { Text(group.senders.joined(separator: "、")) }
                        Text(group.count > 1
                             ? "\(group.count) 条消息"
                             : Date(timeIntervalSince1970: group.latest.message.timestamp).formatted(date: .abbreviated, time: .shortened))
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(24)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(group.items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(item.message.sender).font(.caption.weight(.semibold))
                                    Text(Date(timeIntervalSince1970: item.message.timestamp).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text(item.message.text).textSelection(.enabled).font(.body)
                                    .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(24)
                }
                Spacer(minLength: 0)
                Divider()
                HStack(spacing: 10) {
                    Spacer()
                    Menu {
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button("\(minutes) 分钟后") { model.move(group, to: .later, due: Date().addingTimeInterval(Double(minutes * 60))) }
                        }
                        Button("选择日期与时间…") { customReminder = group }
                    } label: { Label("稍后提醒", systemImage: "clock") }
                        .fixedSize()
                    if group.items.allSatisfy({ $0.bucket == .done }) {
                        Button("移回待处理") { model.move(group, to: .pending) }
                    } else {
                        Button { model.move(group, to: .done) } label: { Label("标为已处理", systemImage: "checkmark") }
                            .inboxProminentButton()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(palette.reader)
            }
        } else {
            VStack(spacing: 13) {
                if model.detecting { ProgressView().controlSize(.regular) }
                else {
                    Brand(size: 116)
                }
                Text(model.detecting ? "正在查找消息库" : model.source == nil ? "尚未找到可读的消息库" : model.query.isEmpty ? "暂无\(model.bucket.title)消息" : "未找到匹配消息")
                    .font(.title2.weight(.semibold))
                if model.source == nil && !model.detecting {
                    Text("可重新查找桌面、文稿和下载目录，\n也可以选择其他位置的 SQLite 文件。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(3)
                    HStack {
                        Button("重新查找") { Task { await model.refresh(findSource: true) } }.inboxProminentButton()
                        Button("选择其他文件…") { model.choose() }
                    }.controlSize(.large).disabled(model.busy)
                } else if model.source != nil && model.bucket == .pending && model.query.isEmpty {
                    Text(model.paused ? "已暂停收录，可在设置中恢复。" : "只有所选文件新增记录，消息才会出现在这里。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let source = model.source, model.query.isEmpty, let date = model.latestSourceMessage {
                    VStack(spacing: 3) {
                        Text(source.lastPathComponent)
                        Text("文件内最新消息 " + date.formatted(date: .abbreviated, time: .standard))
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let problem = model.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(24)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    @State private var confirmRetention = false
    @State private var keyInput = ""
    @AppStorage("appearance") private var appearance = InboxAppearance.system
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("数据源与设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() } }
            Picker("外观", selection: $appearance) {
                ForEach(InboxAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if let url = model.source {
                Text(url.path).font(.callout).textSelection(.enabled).foregroundStyle(.secondary)
            } else { Text("尚未连接数据源").foregroundStyle(.secondary) }
            HStack {
                Button(model.detecting ? "正在查找…" : "自动查找") { Task { await model.refresh(findSource: true) } }.disabled(model.busy)
                Button("选择其他文件…") { model.choose() }.disabled(model.busy)
                if model.source != nil { Button(model.paused ? "恢复收录" : "暂停收录") { model.pause() } }
            }
            if let note = model.discoveryNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let date = model.latestSourceMessage {
                Text("文件内最新消息 " + date.formatted(date: .abbreviated, time: .standard)).font(.callout)
            }
            if let date = model.lastCheck { Text("上次检查 \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            if let problem = model.problem { Text(problem).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            Label("钉钉实时数据源", systemImage: "bolt.horizontal.circle").font(.headline)
            HStack {
                Circle().fill(model.keyConfigured ? jade : Color.orange).frame(width: 7, height: 7)
                Text(model.keyConfigured ? "已配置数据库密钥" : "未配置数据库密钥")
                Spacer()
                if model.isLiveSource { Text("实时读取中").font(.caption).foregroundStyle(jade) }
            }
            if let url = model.source, model.isLiveSource {
                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                SecureField("16 个字符或 32 位十六进制", text: $keyInput)
                Button("保存密钥") { model.saveDingTalkKey(keyInput); keyInput = "" }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("密钥仅保存在本机，用于直接解密正在被钉钉写入的 dingtalk.db；配置后可自动连接实时库。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("登录 Mac 时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            HStack {
                Stepper("保留消息 \(days) 天", value: $days, in: 1...365)
                Spacer()
                if days != model.retention {
                    Button("应用") {
                        if days < model.retention { confirmRetention = true }
                        else { model.setRetention(days) }
                    }
                }
            }
            Label("本地逐条加密", systemImage: "lock").font(.headline)
            Text("回复箱使用 AES-256-GCM 保存消息，密钥存放在 macOS 钥匙串。提醒通知隐藏消息正文。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack { Brand(size: 34); Text("DingLater Mac").font(.headline); Spacer(); Text("MIT · 只供学习使用").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 440).tint(jade)
            .onAppear { days = model.retention }
            .confirmationDialog("缩短本地消息保留期限？", isPresented: $confirmRetention) {
                Button("应用并清理过期消息", role: .destructive) { model.setRetention(days) }
            } message: { Text("早于新期限的回复箱记录将被删除。") }
    }
}

struct ReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var due = Date().addingTimeInterval(1800)
    let save: (Date) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("稍后提醒").font(.title2.weight(.semibold))
            DatePicker("提醒时间", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存提醒") { save(due); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).tint(jade)
    }
}


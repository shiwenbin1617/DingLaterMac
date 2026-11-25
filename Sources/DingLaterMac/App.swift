import AppKit
import DingLaterCore
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct DingLaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    @AppStorage("appearance") private var appearance = InboxAppearance.system
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("DingLater", id: "inbox") {
            InboxView(model: model)
                .preferredColorScheme(appearance.scheme)
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { $0.apply() }
        }
        .defaultSize(width: 1010, height: 640)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DingLater Mac") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "DingLater Mac",
                        .credits: NSAttributedString(string: "只供学习使用 · MIT License")
                    ])
                }
            }
            CommandGroup(after: .appSettings) {
                Button("数据源与设置…") { showWindow(); model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        MenuBarExtra {
            Button("打开回复箱") { showWindow() }
            ForEach(Bucket.allCases, id: \.self) { value in
                Button("\(value.title)（\(model.count(value))）") { model.bucket = value; model.selected = nil; showWindow() }
            }
            Divider()
            if model.source != nil {
                Button(model.paused ? "恢复收录" : "暂停收录") { model.pause() }
            }
            Button("数据源与设置…") { showWindow(); model.showSettings = true }
            Divider()
            Button("退出 DingLater") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "tray")
            if model.count(.pending) > 0 { Text("\(model.count(.pending))") }
        }
    }

    private func showWindow() {
        openWindow(id: "inbox")
        NSApp.activate(ignoringOtherApps: true)
    }
}


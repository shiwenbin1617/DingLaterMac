import AppKit
import SwiftUI

enum InboxAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }

    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct InboxPalette {
    let sidebar: Color
    let list: Color
    let reader: Color
    let highlight: Color
    let searchField: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            sidebar = Color(red: 0.075, green: 0.108, blue: 0.112)
            list = Color(red: 0.101, green: 0.125, blue: 0.128)
            reader = Color(red: 0.115, green: 0.142, blue: 0.145)
            highlight = Color(red: 0.44, green: 0.88, blue: 0.75)
            searchField = .white.opacity(0.07)
        } else {
            sidebar = Color(red: 0.922, green: 0.950, blue: 0.942)
            list = Color(red: 0.977, green: 0.980, blue: 0.971)
            reader = Color(red: 0.998, green: 0.995, blue: 0.982)
            highlight = Color(red: 0.05, green: 0.41, blue: 0.33)
            searchField = .black.opacity(0.045)
        }
    }
}

extension View {
    @ViewBuilder func inboxGlass<S: Shape>(in shape: S, tint: Color, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape).background(tint, in: shape)
        }
    }

    @ViewBuilder func inboxProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}


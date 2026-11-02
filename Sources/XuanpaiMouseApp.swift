import AppKit
import SwiftUI

/// Dock 图标策略：默认不显示（纯菜单栏应用），可在菜单里开启
enum DockIconPolicy {
    static let defaultsKey = "showInDock"

    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        DockIconPolicy.apply(UserDefaults.standard.bool(forKey: DockIconPolicy.defaultsKey))
    }
}

@main
struct XuanpaiMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = MouseStore()

    var body: some Scene {
        // 主窗口启动时不自动弹出，从菜单栏菜单里打开
        Window(L("Xuanpai Mouse"), id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.device)
                .frame(minWidth: 480, idealWidth: 480, minHeight: 620, idealHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarContent(store: store, device: store.device)
        } label: {
            MenuBarLabel(store: store, device: store.device)
        }
    }
}

import AppKit
import SwiftUI

/// 菜单栏上显示的内容：鼠标图标 + 可选的电量、DPI
struct MenuBarLabel: View {
    @ObservedObject var store: MouseStore
    @ObservedObject var device: MouseDevice
    @AppStorage("menuBar.showBattery") private var showBattery = true
    @AppStorage("menuBar.showDPI") private var showDPI = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "computermouse")
            if let text { Text(text).monospacedDigit() }
        }
    }

    private var text: String? {
        guard device.link != .none else { return nil }
        var parts: [String] = []
        if showBattery, let battery = store.info?.battery { parts.append("\(battery)%") }
        if showDPI, let dpi = store.currentDPI { parts.append("\(dpi)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 点开菜单栏图标后的菜单
struct MenuBarContent: View {
    @ObservedObject var store: MouseStore
    @ObservedObject var device: MouseDevice
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBar.showBattery") private var showBattery = true
    @AppStorage("menuBar.showDPI") private var showDPI = false
    @AppStorage(DockIconPolicy.defaultsKey) private var showInDock = false

    var body: some View {
        if device.link == .none {
            Text(L("Not connected"))
        } else {
            if let battery = store.info?.battery {
                Text(String(format: L("Battery: %d%%"), battery))
            }
            if let dpi = store.currentDPI {
                Text(String(format: L("DPI: %d"), dpi))
            }
        }
        Divider()
        Toggle(L("Show battery in menu bar"), isOn: $showBattery)
        Toggle(L("Show DPI in menu bar"), isOn: $showDPI)
        Toggle(L("Show icon in Dock"), isOn: $showInDock)
            .onChange(of: showInDock) { _, newValue in DockIconPolicy.apply(newValue) }
        Divider()
        Button(L("Open Xuanpai Mouse")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L("Quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

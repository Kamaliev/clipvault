import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only app, also when launched without a bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
        // Background menu-bar app must keep monitoring the clipboard.
        ProcessInfo.processInfo.disableAutomaticTermination("clipboard monitoring")
        Task { @MainActor in AppModel.shared.start() }
    }
}

@main
struct ClipvaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("Clipvault", systemImage: model.paused ? "clipboard" : "doc.on.clipboard") {
            MenuContent(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Show History (\(model.hotKey.display))") { model.togglePopup() }
        Divider()
        Toggle("Pause Recording", isOn: $model.paused)
        Toggle("Auto-Paste", isOn: $model.autoPaste)
        if !model.accessibilityGranted {
            Button("Enable Auto-Paste (Accessibility)…") { model.requestAccessibility() }
        }
        if let warning = model.storageWarning {
            Text(warning)
        }
        Divider()
        Button("Clear History") { model.clearHistory() }
        Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

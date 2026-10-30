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
        if model.sequenceRemaining > 0 {
            Button("Paste Next (\(HotKeySpec.pasteNext.display)) — \(model.sequenceRemaining) left") {
                model.pasteNext(into: nil)
            }
            Button("Stop Paste Sequence") { model.stopSequence() }
            if let error = model.sequenceError { Text(error) }
        }
        Divider()
        Toggle("Pause Recording", isOn: $model.paused)
        Toggle("Auto-Paste", isOn: $model.autoPaste)
        Toggle("Launch at Login", isOn: $model.launchAtLogin)
        if !model.accessibilityGranted {
            Button("Enable Auto-Paste (Accessibility)…") { model.requestAccessibility() }
        }
        if let warning = model.storageWarning {
            Text(warning)
        }
        Divider()
        Button("Clear History (Keep Pinned)") { model.clearHistory() }
        Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

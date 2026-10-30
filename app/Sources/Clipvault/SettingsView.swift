import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            LabeledContent("Hotkey") {
                HStack {
                    Button(recording ? "Press a shortcut…" : model.hotKey.display) { toggleRecording() }
                        .frame(minWidth: 140)
                    Button("Reset") { model.hotKey = .default }
                }
            }
            if let error = model.hotKeyError {
                Text(error).foregroundStyle(.red)
            }
            Toggle("Paste selected item automatically (⌘V)", isOn: $model.autoPaste)
            Toggle("Recognize text in images for search (on-device)", isOn: $model.recognizeText)
            Picker("Menu bar icon", selection: $model.alwaysShowMenuBarIcon) {
                Text("Only while in use").tag(false)
                Text("Always").tag(true)
            }
            if !model.alwaysShowMenuBarIcon {
                Text("Open Settings with ⌘, in the history popup or by launching Clipvault again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .disabled(!LaunchAtLogin.isAvailable)
            if let error = model.launchAtLoginError {
                HStack {
                    Text(error).foregroundStyle(.orange)
                    Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                }
            }
            LabeledContent("Accessibility access") {
                if model.accessibilityGranted {
                    Text("granted").foregroundStyle(.green)
                } else {
                    Button("Request…") { model.requestAccessibility() }
                }
            }
            if !model.accessibilityGranted {
                Text("If Clipvault is already switched on in System Settings, remove it with − and request again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Storage") {
                Text("24 hours (pinned kept), XChaCha20-Poly1305, key in Keychain")
                    .foregroundStyle(.secondary)
            }
            if let warning = model.storageWarning {
                Text(warning).foregroundStyle(.orange)
            }
            LabeledContent("Items") {
                HStack {
                    Text("\(model.entryCount)")
                    Button("Clear") { model.clearHistory() }
                        .help("Delete all items except pinned ones")
                    Button("Clear All") { model.clearHistory(includingPinned: true) }
                        .help("Delete everything, including pinned items")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc cancels
                stopRecording()
                return nil
            }
            guard let spec = HotKeySpec(event: event) else { return nil }
            model.hotKey = spec
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

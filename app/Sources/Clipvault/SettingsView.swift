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
            LabeledContent("Accessibility access") {
                if model.accessibilityGranted {
                    Text("granted").foregroundStyle(.green)
                } else {
                    Button("Request…") { model.requestAccessibility() }
                }
            }
            LabeledContent("Storage") {
                Text("24 hours, XChaCha20-Poly1305, key in Keychain")
                    .foregroundStyle(.secondary)
            }
            if let warning = model.storageWarning {
                Text(warning).foregroundStyle(.orange)
            }
            LabeledContent("Items") {
                HStack {
                    Text("\(model.entryCount)")
                    Button("Clear") { model.clearHistory() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
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

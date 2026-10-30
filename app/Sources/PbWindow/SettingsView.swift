import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Form {
            LabeledContent("Горячая клавиша") {
                HStack {
                    Button(recording ? "Нажмите сочетание…" : model.hotKey.display) { toggleRecording() }
                        .frame(minWidth: 140)
                    Button("Сбросить") { model.hotKey = .default }
                }
            }
            if let error = model.hotKeyError {
                Text(error).foregroundStyle(.red)
            }
            Toggle("Автоматически вставлять выбранное (⌘V)", isOn: $model.autoPaste)
            LabeledContent("Доступ Accessibility") {
                if model.accessibilityGranted {
                    Text("разрешён").foregroundStyle(.green)
                } else {
                    Button("Запросить…") { model.requestAccessibility() }
                }
            }
            LabeledContent("Хранение") {
                Text("24 часа, шифрование XChaCha20-Poly1305, ключ в Keychain")
                    .foregroundStyle(.secondary)
            }
            if let warning = model.storageWarning {
                Text(warning).foregroundStyle(.orange)
            }
            LabeledContent("Записей") {
                HStack {
                    Text("\(model.entryCount)")
                    Button("Очистить") { model.clearHistory() }
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

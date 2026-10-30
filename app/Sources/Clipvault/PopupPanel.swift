import AppKit
import SwiftUI

/// Non-activating floating panel: it takes keyboard focus without activating our app,
/// so the previously active app stays frontmost and receives the ⌘V.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        minSize = NSSize(width: 380, height: 260)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    private let panel = PopupPanel()
    private let viewModel: HistoryViewModel
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private let onChoose: (Int64, NSRunningApplication?) -> Void

    init(store: Store, onChoose: @escaping (Int64, NSRunningApplication?) -> Void) {
        viewModel = HistoryViewModel(store: store)
        self.onChoose = onChoose
        super.init()
        viewModel.onChoose = { [weak self] id in self?.choose(id) }
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryView(model: viewModel))
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        viewModel.prepare(accessibilityGranted: Paster.isTrusted)
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    func refreshIfVisible() {
        if isVisible { viewModel.reload() }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func choose(_ id: Int64) {
        close()
        onChoose(id, previousApp)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.62 - size.height / 2)
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 125: viewModel.move(1); return true // ↓
        case 126: viewModel.move(-1); return true // ↑
        case 36, 76: viewModel.chooseSelected(); return true // ⏎
        case 53: close(); return true // esc
        case 51 where flags.contains(.command): viewModel.deleteSelected(); return true // ⌘⌫
        default: break
        }
        if flags.contains(.command), let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            viewModel.choose(index: n - 1)
            return true
        }
        return false
    }
}

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
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Translucent backdrop showing what is behind the window: Liquid Glass on macOS 26+,
/// classic behind-window vibrancy on older systems.
@MainActor
func makeGlassContainer(hosting content: NSView, cornerRadius: CGFloat = 24) -> NSView {
    #if compiler(>=6.2)
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    #endif
    let effect = NSVisualEffectView()
    effect.material = .menu
    effect.blendingMode = .behindWindow
    // The panel never activates the app, so force the active look instead of the grey inactive one.
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = cornerRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        content.topAnchor.constraint(equalTo: effect.topAnchor),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    return effect
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    private let panel = PopupPanel()
    private let viewModel: HistoryViewModel
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private let onAction: (ClipAction, Int64, NSRunningApplication?) -> Void
    private let onSequence: ([Int64], NSRunningApplication?) -> Void

    init(store: Store,
         onAction: @escaping (ClipAction, Int64, NSRunningApplication?) -> Void,
         onSequence: @escaping ([Int64], NSRunningApplication?) -> Void) {
        viewModel = HistoryViewModel(store: store)
        self.onAction = onAction
        self.onSequence = onSequence
        super.init()
        viewModel.onAction = { [weak self] action, id in
            guard let self else { return }
            self.close()
            self.onAction(action, id, self.previousApp)
        }
        viewModel.onSequence = { [weak self] ids in
            guard let self else { return }
            self.close()
            self.onSequence(ids, self.previousApp)
        }
        panel.delegate = self
        let hosting = NSHostingView(rootView: HistoryView(model: viewModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = makeGlassContainer(hosting: hosting)
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
        panel.invalidateShadow()
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    func refreshIfVisible() {
        if isVisible { viewModel.reload() }
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
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
        let mods = flags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 125: viewModel.move(1); return true // ↓
        case 126: viewModel.move(-1); return true // ↑
        case 36, 76: // ⏎
            switch mods {
            case []: viewModel.perform(.paste)
            case .shift: viewModel.perform(.pastePlain)
            case .command: viewModel.perform(.copy)
            case .option: viewModel.startSequence()
            default: return false
            }
            return true
        case 53: // esc
            if !viewModel.closePreview() { close() }
            return true
        case 51 where mods == .command: viewModel.delete(); return true // ⌘⌫
        case 35 where mods == .command: viewModel.togglePin(); return true // ⌘P
        case 16 where mods == .command: viewModel.togglePreview(); return true // ⌘Y
        default: break
        }
        if flags.contains(.command), let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            viewModel.choose(index: n - 1)
            return true
        }
        return false
    }
}

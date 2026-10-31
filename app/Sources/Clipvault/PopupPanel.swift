import AppKit
import Combine
import SwiftUI

/// Non-activating floating panel: it takes keyboard focus without activating our app,
/// so the previously active app stays frontmost and receives the ⌘V.
final class PopupPanel: NSPanel {
    nonisolated static let cornerRadius: CGFloat = 18

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            // Borderless: no system frame, so only our glass defines the rounded corners.
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: true
        )
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        minSize = NSSize(width: 380, height: 260)
        isOpaque = false
        backgroundColor = .clear
        // The system shadow of a borderless window draws a dark hairline around the glass.
        hasShadow = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Translucent backdrop showing what is behind the window: Liquid Glass on macOS 26+,
/// classic behind-window vibrancy on older systems.
@MainActor
func makeGlassContainer(hosting content: NSView, cornerRadius: CGFloat = PopupPanel.cornerRadius) -> NSView {
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
    // A layer corner radius does not clip behind-window blur; a stretchable mask image does.
    let side = cornerRadius * 2 + 1
    let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
    mask.resizingMode = .stretch
    effect.maskImage = mask
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
    /// Called when the popup is shown (`true`) or hidden (`false`).
    var onVisibilityChange: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var maskSecrets: Bool {
        get { viewModel.maskingEnabled }
        set { viewModel.maskingEnabled = newValue }
    }
    private let previewer = PreviewController()
    private var previewObserver: AnyCancellable?
    /// Popup origin before it moved aside for the preview window.
    private var originBeforePreview: NSPoint?
    // Group drag: a hidden view is the `NSDraggingSource` we start the session on; the monitor
    // watches for a drag gesture inside the list and hands off to `beginDraggingSession`.
    private let dragHost = NSView(frame: .zero)
    private let dragSource = DragSource()
    private var mouseMonitor: Any?
    private var isDragging = false
    private var dragArmed = false
    private var mouseDownPoint: NSPoint?

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
        if let content = panel.contentView {
            dragHost.frame = .zero
            content.addSubview(dragHost)
        }
        // When the group is dropped or cancelled, clear the guard and close the popup.
        dragSource.onEnded = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDragging = false
                self.close()
            }
        }
        previewObserver = viewModel.$preview
            .dropFirst()
            .sink { [weak self] preview in self?.updatePreview(preview) }
    }

    /// Shows the Quick Look–style window beside the popup, moving the popup so both fit.
    private func updatePreview(_ preview: ClipPreview?) {
        guard let preview, panel.isVisible else {
            previewer.hide()
            if let origin = originBeforePreview, panel.isVisible { panel.setFrameOrigin(origin) }
            originBeforePreview = nil
            return
        }
        if originBeforePreview == nil { originBeforePreview = panel.frame.origin }
        let popup = previewer.show(preview, beside: panel.frame, on: panel.screen)
        if popup != panel.frame { panel.setFrame(popup, display: true) }
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
        onVisibilityChange?(true)
        installKeyMonitor()
        installDragMonitor()
    }

    func close() {
        removeKeyMonitor()
        removeDragMonitor()
        previewer.hide()
        originBeforePreview = nil
        _ = viewModel.closePreview()
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { onVisibilityChange?(false) }
    }

    func refreshIfVisible() {
        if isVisible { viewModel.reload() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        panel.setFrame(panel.frame.pixelAligned, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Don't close mid-drag: handing off to the target app can drop focus away from the popup.
        guard !isDragging else { return }
        close()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.62 - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame.pixelAligned, display: false)
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

    /// Watches for a drag gesture inside the list body and starts a multi-item AppKit drag of
    /// the whole selection. A local monitor passes the events through, so scrolling and taps
    /// still work; only a button-held move past a threshold becomes a drag.
    private func installDragMonitor() {
        removeDragMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handleDrag(event)
            return event
        }
    }

    private func removeDragMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        dragArmed = false
        mouseDownPoint = nil
    }

    private func handleDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = event.locationInWindow
            // A drag only starts from the list body, and only when a group is selected.
            dragArmed = !viewModel.selected.isEmpty && inList(event.locationInWindow)
        case .leftMouseDragged:
            guard dragArmed, let start = mouseDownPoint, !isDragging else { return }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard hypot(dx, dy) > 5 else { return }
            startDrag(with: event)
        case .leftMouseUp:
            dragArmed = false
        default:
            break
        }
    }

    /// The search field (top) and footer (bottom) are not drag starts; only the list body is.
    private func inList(_ p: NSPoint) -> Bool {
        let h = panel.frame.height
        return p.y > 36 && p.y < h - 64
    }

    private func startDrag(with event: NSEvent) {
        let items = viewModel.makeDragItems()
        guard !items.isEmpty else { return }
        isDragging = true
        if let session = dragHost.beginDraggingSession(with: items, event: event, source: dragSource) {
            session.beginDrag(with: items)
            // One drag per gesture; stop watching so a second move can't re-start it.
            removeDragMonitor()
        } else {
            isDragging = false
        }
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
            // Esc first collapses a group to the cursor row, then the preview, then the panel.
            if viewModel.collapseSelection() { return true }
            if !viewModel.closePreview() { close() }
            return true
        case 51 where mods == .command: viewModel.delete(); return true // ⌘⌫
        case 35 where mods == .command: viewModel.togglePin(); return true // ⌘P
        case 0 where mods == .command: viewModel.selectAll(); return true // ⌘A
        case 43 where mods == .command: // ⌘,
            close()
            onOpenSettings?()
            return true
        case 16 where mods == .command: viewModel.togglePreview(); return true // ⌘Y
        case 15 where mods == .command && previewer.isVisible: viewModel.toggleReveal(); return true // ⌘R
        // Space previews like Finder; with a search query it types a space instead.
        case 49 where mods.isEmpty && (viewModel.query.isEmpty || previewer.isVisible):
            viewModel.togglePreview(); return true
        case 24 where previewer.isVisible && mods.subtracting(.shift) == .command: previewer.zoom(1); return true // ⌘+ / ⌘=
        case 27 where previewer.isVisible && mods == .command: previewer.zoom(-1); return true // ⌘−
        case 29 where previewer.isVisible && mods == .command: previewer.zoom(0); return true // ⌘0
        default: break
        }
        if flags.contains(.command), let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            viewModel.choose(index: n - 1)
            return true
        }
        return false
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Restores a stored entry to the pasteboard and optionally sends ⌘V to the frontmost app.
enum Paster {
    static func write(_ reps: [ClipRep], to pasteboard: NSPasteboard = .general) {
        var items: [UInt32: NSPasteboardItem] = [:]
        var order: [UInt32] = []
        for rep in reps {
            let item = items[rep.item] ?? {
                order.append(rep.item)
                let created = NSPasteboardItem()
                items[rep.item] = created
                return created
            }()
            item.setData(rep.data, forType: .init(rep.uti))
        }
        let ordered = order.compactMap { items[$0] }
        if let first = ordered.first {
            first.setData(Data(), forType: PasteboardMonitor.ownType)
            first.setString(Bundle.main.bundleIdentifier ?? "com.kamaliev.pb-window",
                            forType: .init("org.nspasteboard.source"))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(ordered)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Sends ⌘V. Requires the Accessibility permission.
    static func sendPasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

import AppKit

/// Creates one drag item for one stored pasteboard item.
enum ClipDragItem {
    static func make(
        reps: [(NSPasteboard.PasteboardType, Data)],
        thumbnail: NSImage?,
        at point: NSPoint
    ) -> NSDraggingItem {
        let writer = NSPasteboardItem()
        for (type, data) in reps {
            writer.setData(data, forType: type)
        }

        let item = NSDraggingItem(pasteboardWriter: writer)
        if let thumbnail {
            let frame = NSRect(
                x: point.x - thumbnail.size.width / 2,
                y: point.y - thumbnail.size.height / 2,
                width: thumbnail.size.width,
                height: thumbnail.size.height
            )
            item.setDraggingFrame(frame, contents: thumbnail)
        }
        return item
    }
}

/// The source clears the in-drag guard and closes the popup when the drag ends.
final class DragSource: NSObject, NSDraggingSource {
    var onEnded: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnded?()
    }
}

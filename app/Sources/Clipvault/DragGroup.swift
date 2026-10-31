import AppKit

/// One pasteboard item of a group drag = one stored record's one `item` group. A multi-file
/// record (several `item`s) therefore produces several items. It carries the record's
/// representations, so dropping the group lands as the same content a paste would: image
/// UTIs, file URLs, or plain text.
final class ClipDragItem: NSDraggingItem {
    private let reps: [(NSPasteboard.PasteboardType, Data)]
    private let thumbnail: NSImage?

    init(reps: [(NSPasteboard.PasteboardType, Data)], thumbnail: NSImage?) {
        self.reps = reps
        self.thumbnail = thumbnail
        super.init(pasteboard: nil)
    }

    override var availableTypes: [NSPasteboard.PasteboardType] {
        reps.map(\.0)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType)
        -> [NSPasteboard.WritingOption: NSPasteboard.WritingOptions] {
        [:]
    }

    override func writeItems(to sender: NSPasteboardWriting,
                             options: NSPasteboard.WritingOptions,
                             forType type: NSPasteboard.PasteboardType) -> Bool {
        guard let data = reps.first(where: { $0 == type })?.1 else { return false }
        return sender.writeData(data, forType: type)
    }

    /// A small image so the dragged stack looks like what it carries; `nil` for text.
    override func draggingImage(offset: NSPoint) -> (NSImage, NSPoint)? {
        guard let thumbnail else { return nil }
        return (thumbnail, NSPoint(x: thumbnail.size.width / 2, y: 0))
    }
}

/// The source we hand to `beginDraggingSession`; it only needs `draggingEnded` so the caller
/// can clear its in-drag guard and close the popup when the group is dropped or cancelled.
final class DragSource: NSObject, NSDraggingSource {
    var onEnded: (() -> Void)?

    func draggingEnded(_ session: NSDraggingSession) {
        onEnded?()
    }
}

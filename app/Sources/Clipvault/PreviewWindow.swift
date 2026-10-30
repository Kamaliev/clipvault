import AppKit

/// Quick Look–style preview shown next to the history popup. It never becomes key, so the
/// popup keeps the keyboard (↑↓ browse, zoom keys) while the preview still gets scroll,
/// pinch and click events.
final class PreviewPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Darkens/lightens the glass so large content stays legible; follows the glass corners.
private final class ScrimView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PopupPanel.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.35)
                                       : NSColor.white.withAlphaComponent(0.5)).cgColor
    }
}

/// Keeps a document smaller than the viewport centered instead of pinned to a corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

@MainActor
final class PreviewController {
    private let panel = PreviewPanel()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let textView = NSTextView()
    private var showingImage = false
    private var textSize: CGFloat = 14
    private var shownID: Int64?

    var isVisible: Bool { panel.isVisible }

    init() {
        let scrim = ScrimView()

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 2

        let separator = NSBox()
        separator.boxType = .separator

        scroll.contentView = CenteringClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.wantsLayer = true
        // Crisp pixels when zoomed past 100%, like Preview/Quick Look.
        imageView.layer?.magnificationFilter = .nearest

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textColor = .labelColor

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFit))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        for view in [header, separator, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            scrim.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: scrim.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: scrim.trailingAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: scrim.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: scrim.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: scrim.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: scrim.trailingAnchor, constant: -6),
            // Keep content clear of the rounded bottom corners.
            scroll.bottomAnchor.constraint(equalTo: scrim.bottomAnchor, constant: -10),
        ])
        panel.contentView = makeGlassContainer(hosting: scrim)
    }

    /// Shows `preview` in a large window placed beside `anchor`; returns the frame the anchor
    /// window should move to so both fit on screen.
    @discardableResult
    func show(_ preview: ClipPreview, beside anchor: NSRect, on screen: NSScreen?) -> NSRect {
        titleLabel.stringValue = preview.title
        subtitleLabel.stringValue = preview.subtitle
        let sameItem = preview.id == shownID && panel.isVisible
        shownID = preview.id
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return anchor }
        let gap: CGFloat = 12
        let width = max(360, min(1200, visible.width - anchor.width - gap * 3))
        let height = max(anchor.height, min(visible.height - gap * 2, visible.height * 0.86, 1000))
        let total = anchor.width + gap + width
        let left = max(visible.minX + gap, visible.midX - total / 2)
        var popup = anchor
        popup.origin.x = left
        popup.origin.y = min(max(anchor.minY, visible.minY + gap), visible.maxY - gap - anchor.height)
        let previewY = min(max(popup.midY - height / 2, visible.minY + gap), visible.maxY - gap - height)
        let frame = NSRect(x: popup.maxX + gap, y: previewY, width: width, height: height)
        if panel.frame != frame.pixelAligned { panel.setFrame(frame.pixelAligned, display: false) }
        if !sameItem {
            setContent(preview)
            if showingImage { fit() }
        }
        panel.orderFront(nil)
        return popup.pixelAligned
    }

    func hide() {
        panel.orderOut(nil)
        shownID = nil
    }

    /// `+1` zoom in, `-1` zoom out, `0` fit (image) or default size (text).
    func zoom(_ step: Int) {
        if showingImage {
            switch step {
            case 0: toggleFit()
            default:
                let factor: CGFloat = step > 0 ? 1.25 : 0.8
                scroll.setMagnification(scroll.magnification * factor,
                                        centeredAt: scroll.contentView.bounds.center)
            }
        } else {
            textSize = step == 0 ? 14 : min(max(textSize + CGFloat(step) * 2, 9), 48)
            textView.font = .monospacedSystemFont(ofSize: textSize, weight: .regular)
        }
    }

    private func setContent(_ preview: ClipPreview) {
        if let image = preview.image {
            showingImage = true
            scroll.allowsMagnification = true
            scroll.magnification = 1
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            scroll.documentView = imageView
        } else {
            showingImage = false
            scroll.allowsMagnification = false
            scroll.magnification = 1
            textView.font = .monospacedSystemFont(ofSize: textSize, weight: .regular)
            textView.string = preview.text ?? ""
            textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
            scroll.documentView = textView
            textView.scroll(.zero)
        }
    }

    /// Fits the image into the window, never upscaling small images.
    private func fit() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        scroll.layoutSubtreeIfNeeded()
        let available = scroll.contentView.frame.size
        let scale = min(1, available.width / size.width, available.height / size.height)
        scroll.magnification = scale
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
    }

    /// Double click / ⌘0: toggles between fit-to-window and actual size.
    @objc private func toggleFit() {
        guard showingImage, let size = imageView.image?.size else { return }
        let available = scroll.contentView.frame.size
        let fitScale = min(1, available.width / size.width, available.height / size.height)
        if abs(scroll.magnification - fitScale) < 0.001, fitScale < 1 {
            scroll.setMagnification(1, centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
        } else {
            fit()
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

extension NSRect {
    /// Snaps to whole points; fractional window frames make text render blurry.
    var pixelAligned: NSRect {
        NSRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

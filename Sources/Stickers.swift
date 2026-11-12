import AppKit

/// A photo, video or drawing placed on the page. Drag to move, drag the corner to resize,
/// double-click to open, right-click for more. Lives inside the text view, so it scrolls with the writing.
final class StickerView: NSView {
    let attachment: Attachment
    var onChange: ((NSRect) -> Void)?       // while dragging (text re-wraps live)
    var onCommit: ((NSRect) -> Void)?       // when the drag ends (saved)
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var onFront: (() -> Void)?
    /// height ÷ width, once the image has loaded
    private(set) var aspect: CGFloat?
    var onAspect: ((CGFloat) -> Void)?

    private let imageLayer = CALayer()
    private let playLayer = CATextLayer()
    private var dragStart: NSPoint = .zero
    private var frameStart: NSRect = .zero
    private var resizing = false
    private static let handle: CGFloat = 16
    private var framed: Bool { attachment.isDrawing != true }

    init(attachment: Attachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        if framed {
            layer?.backgroundColor = NSColor(Theme.card).cgColor
            layer?.borderColor = NSColor(Theme.line).cgColor
            layer?.borderWidth = 1
            layer?.shadowColor = NSColor(red: 0.35, green: 0.25, blue: 0.1, alpha: 1).cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 5
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        if attachment.kind == .video {
            playLayer.string = "▶"
            playLayer.fontSize = 18
            playLayer.foregroundColor = NSColor.white.cgColor
            playLayer.alignmentMode = .center
            playLayer.shadowOpacity = 0.4
            playLayer.shadowRadius = 2
            playLayer.contentsScale = 2
            layer?.addSublayer(playLayer)
        }
        Task { @MainActor in
            guard let img = await Thumbnailer.image(for: attachment, maxPixels: 900),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.imageLayer.contents = cg
            let a = CGFloat(cg.height) / CGFloat(max(1, cg.width))
            self.aspect = a
            self.onAspect?(a)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: selection + copy / cut / delete

    override var acceptsFirstResponder: Bool { true }

    private var selected = false {
        didSet {
            layer?.borderColor = NSColor(selected ? Theme.ink : Theme.line).cgColor
            layer?.borderWidth = selected ? 1.5 : (framed ? 1 : 0)
        }
    }

    override func becomeFirstResponder() -> Bool { selected = true; return true }
    override func resignFirstResponder() -> Bool { selected = false; return true }

    @objc func copy(_ sender: Any?) { MediaClipboard.copy(attachment) }
    @objc func cut(_ sender: Any?) { MediaClipboard.copy(attachment); onRemove?() }
    @objc func delete(_ sender: Any?) { onRemove?() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 51, 117: onRemove?()                                   // delete / forward delete
        case 53: window?.makeFirstResponder(superview)               // esc: back to writing
        default: super.keyDown(with: e)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // a thin white mat around photos, like a print
        imageLayer.frame = framed ? bounds.insetBy(dx: 4, dy: 4) : bounds
        playLayer.frame = CGRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        layer?.shadowPath = framed ? CGPath(rect: bounds, transform: nil) : nil
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(NSRect(x: bounds.maxX - Self.handle, y: bounds.maxY - Self.handle, width: Self.handle, height: Self.handle),
                      cursor: .crosshair)
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onOpen?(); return }
        window?.makeFirstResponder(self)
        onFront?()
        dragStart = superview?.convert(e.locationInWindow, from: nil) ?? .zero
        frameStart = frame
        let p = convert(e.locationInWindow, from: nil)
        resizing = p.x > bounds.maxX - Self.handle && p.y > bounds.maxY - Self.handle
        (resizing ? NSCursor.crosshair : NSCursor.closedHand).push()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let sv = superview else { return }
        let p = sv.convert(e.locationInWindow, from: nil)
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        var f = frameStart
        if resizing {
            let a = aspect ?? (frameStart.height / max(1, frameStart.width))
            f.size.width = min(max(60, frameStart.width + dx), sv.bounds.width - f.minX)
            f.size.height = f.width * a
        } else {
            f.origin.x = min(max(0, frameStart.minX + dx), sv.bounds.width - f.width)
            f.origin.y = max(0, frameStart.minY + dy)
        }
        frame = f
        onChange?(f)
    }

    override func mouseUp(with e: NSEvent) {
        NSCursor.pop()
        if frame != frameStart { onCommit?(frame) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Open", action: #selector(openAction), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Bring to Front", action: #selector(frontAction), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Remove", action: #selector(removeAction), keyEquivalent: "").target = self
        return m
    }

    @objc private func openAction() { onOpen?() }
    @objc private func frontAction() { onFront?() }
    @objc private func removeAction() { onRemove?() }
}

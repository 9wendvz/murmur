import SwiftUI
import AppKit
import ImageIO

/// A plain paper page you type on.
struct NotebookEditor: NSViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    /// Photos, videos and drawings placed on the page.
    var stickers: [Attachment] = []
    var onPlace: (UUID, Placement) -> Void = { _, _ in }
    var onOpen: (Attachment) -> Void = { _ in }
    var onRemove: (Attachment) -> Void = { _ in }
    var onImport: (PastedMedia, Placement) -> Void = { _, _ in }
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 30

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let tv = NotebookTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.lineHeight = lineHeight
        tv.font = NSFont(name: "Osaka-Mono", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textColor = NSColor(Theme.ink)
        tv.insertionPointColor = .clear     // the system caret is hidden; NotebookTextView draws its own
        tv.textContainerInset = NSSize(width: 22, height: 14)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Natural line height plus spacing between lines (not a fixed line height): the system caret
        // follows the line's height, so this keeps it the size of the letters (15pt) instead of 30pt.
        let para = NSMutableParagraphStyle()
        if let f = tv.font { para.lineSpacing = max(0, lineHeight - (f.ascender - f.descender + f.leading)) }
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: tv.font!, .foregroundColor: NSColor(Theme.ink), .paragraphStyle: para]

        tv.string = text
        tv.applyStyle()
        tv.delegate = context.coordinator
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let tv = scroll.documentView as? NotebookTextView else { return }
        tv.onPlace = onPlace
        tv.onOpen = onOpen
        tv.onRemove = onRemove
        tv.onImport = onImport
        tv.setStickers(stickers)
        guard tv.string != text else { return }
        tv.string = text
        tv.applyStyle()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            onChange(tv.string)
        }
    }
}

final class NotebookTextView: NSTextView {
    // MARK: custom caret
    //
    // The system caret is as tall as the line fragment — 30pt on an empty page here — and can't be made
    // thinner. So it's hidden (clear colour) and this thin view is placed at the insertion point instead,
    // sized to the font's glyph height, and blinked with a timer.

    private let caret: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(Theme.ink).cgColor
        v.isHidden = true
        return v
    }()
    private var blink: Timer?

    /// Where the caret goes for the current insertion point, in view coordinates (nil when there's a selection).
    func caretFrame() -> NSRect? {
        guard selectedRange().length == 0, let f = font else { return nil }
        let height = (f.ascender - f.descender).rounded()
        var x = textContainerOrigin.x, y = textContainerOrigin.y
        if let tlm = textLayoutManager,
           let loc = tlm.location(tlm.documentRange.location, offsetBy: selectedRange().location) {
            tlm.ensureLayout(for: NSTextRange(location: loc))
            var r: CGRect?
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: .rangeNotRequired) { _, rect, _, _ in
                r = rect; return false
            }
            if let r { x += r.minX; y += r.minY }
        } else if let lm = layoutManager, let tc = textContainer {
            let g = lm.glyphIndexForCharacter(at: selectedRange().location)
            let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 0), in: tc)
            x += r.minX; y += r.minY
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: 1.5, height: height)
    }

    private func updateCaret() {
        if caret.superview == nil { addSubview(caret) }
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        guard active, let frame = caretFrame() else {
            caret.isHidden = true
            blink?.invalidate(); blink = nil
            return
        }
        caret.frame = frame
        caret.isHidden = false
        // restart the blink so the caret stays solid while typing / moving
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caret.isHidden.toggle()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCaret()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true      // so the "…" hint disappears / reappears immediately
        updateCaret()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { self.updateCaret() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { self.updateCaret() }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDragTypeRegistration()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateCaret() }
        }
        updateCaret()
    }

    override func layout() {
        super.layout()
        if !caret.isHidden || blink != nil { caret.frame = caretFrame() ?? caret.frame }
    }

    var lineHeight: CGFloat = 30

    func applyStyle() {
        guard let storage = textStorage else { return }
        storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: storage.length))
        needsDisplay = true
    }

    /// Always at least as tall as the visible area, so the whole page is clickable.
    override func setFrameSize(_ newSize: NSSize) {
        var s = newSize
        if let sv = enclosingScrollView {
            s.width = sv.contentSize.width
            s.height = max(s.height, sv.contentSize.height)
        }
        // tall enough to hold the lowest sticker, so the page scrolls down to it
        if let lowest = stickerViews.values.map(\.frame.maxY).max() { s.height = max(s.height, lowest + 24) }
        let widthChanged = s.width != frame.width
        super.setFrameSize(s)
        if widthChanged { layoutStickers() }
    }

    // MARK: stickers

    var onPlace: (UUID, Placement) -> Void = { _, _ in }
    var onOpen: (Attachment) -> Void = { _ in }
    var onRemove: (Attachment) -> Void = { _ in }
    var onImport: (PastedMedia, Placement) -> Void = { _, _ in }
    private var stickerViews: [UUID: StickerView] = [:]
    private var placements: [UUID: Placement] = [:]
    private var aspects: [UUID: Double] = [:]

    /// Syncs sticker views with the entry's photos/videos/drawings.
    private var lastStickers: [Attachment] = []

    func setStickers(_ items: [Attachment]) {
        guard items != lastStickers else { return }      // typing doesn't touch the stickers
        lastStickers = items
        let ids = Set(items.map(\.id))
        for (id, v) in stickerViews where !ids.contains(id) { v.removeFromSuperview(); stickerViews[id] = nil; placements[id] = nil }
        for (i, a) in items.enumerated() {
            let v = stickerViews[a.id] ?? makeSticker(a)
            // stored placement wins; otherwise its default spot down the right-hand side (recomputed, not
            // cached, so undoing a sticker's first move sends it back there)
            placements[a.id] = a.place ?? {
                var d = defaultPlacement(index: i)
                if let asp = aspects[a.id] { d.aspect = asp }
                if a.isDrawing == true, let (w, asp) = Self.drawingSize(a, pageWidth: EntryEditor.pageWidth) { d.width = w; d.aspect = asp }
                return d
            }()
            if v.superview == nil { addSubview(v) }
        }
        layoutStickers()
    }

    private func makeSticker(_ a: Attachment) -> StickerView {
        let v = StickerView(attachment: a)
        stickerViews[a.id] = v
        v.onChange = { [weak self] _ in self?.updateExclusions() }
        v.onCommit = { [weak self, weak v] f in
            guard let self, let v else { return }
            let p = self.placement(for: f, of: v)
            self.placements[a.id] = p
            self.onPlace(a.id, p)
            self.setFrameSize(self.frame.size)
        }
        v.onAspect = { [weak self, weak v] aspect in
            self?.aspects[a.id] = Double(aspect)
            guard let self, let v, var p = self.placements[a.id], abs(p.aspect - Double(aspect)) > 0.01 else { return }
            p.aspect = Double(aspect)
            self.placements[a.id] = p
            v.frame = self.rect(for: p)
            self.updateExclusions()
            self.setFrameSize(self.frame.size)
        }
        v.onFront = { [weak self, weak v] in
            guard let self, let v, var p = self.placements[a.id] else { return }
            let top = (self.placements.values.map(\.z).max() ?? 0)
            guard p.z < top || self.placements.values.filter({ $0.z == top }).count > 1 else { return }
            p.z = top + 1
            self.placements[a.id] = p
            self.onPlace(a.id, p)
            self.sortStickers()
            _ = v
        }
        v.onOpen = { [weak self] in self?.onOpen(a) }
        v.onRemove = { [weak self] in self?.onRemove(a) }
        return v
    }

    /// A drawing's starting size: about 1.5× how big it was drawn, but no bigger than a photo
    /// (photo width, and about the height of a landscape photo). Returns (width as a page fraction, aspect).
    static func drawingSize(_ a: Attachment, pageWidth: CGFloat) -> (Double, Double)? {
        guard pageWidth > 0,
              let src = CGImageSourceCreateWithURL(a.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? CGFloat, let ph = props[kCGImagePropertyPixelHeight] as? CGFloat,
              pw > 0, ph > 0 else { return nil }
        let aspect = ph / pw
        // doodles are saved at 2× — so pw/2 is the size they were drawn at
        var w = pw / 2 * 1.5
        let maxW = pageWidth * 0.38, maxH: CGFloat = 140
        w = min(w, maxW, maxH / aspect)
        w = max(w, 60)
        return (Double(w / pageWidth), Double(aspect))
    }

    private func defaultPlacement(index i: Int) -> Placement {
        let w = 0.38, aspect = 0.75
        let pageW = max(200, bounds.width)
        let y = 14 + Double(i) * (w * Double(pageW) * aspect + 14)
        return Placement(x: 0.58, y: y, width: w, aspect: aspect, z: i)
    }

    private func rect(for p: Placement) -> NSRect {
        let w = CGFloat(p.width) * bounds.width
        return NSRect(x: CGFloat(p.x) * bounds.width, y: CGFloat(p.y), width: w, height: w * CGFloat(p.aspect))
    }

    private func placement(for f: NSRect, of v: StickerView) -> Placement {
        var p = placements[v.attachment.id] ?? defaultPlacement(index: 0)
        p.x = Double(f.minX / max(1, bounds.width))
        p.y = Double(f.minY)
        p.width = Double(f.width / max(1, bounds.width))
        if let a = v.aspect { p.aspect = Double(a) }
        return p
    }

    private func layoutStickers() {
        for (id, v) in stickerViews { if let p = placements[id] { v.frame = rect(for: p) } }
        sortStickers()
        updateExclusions()
    }

    private func sortStickers() {
        let ordered = stickerViews.sorted { (placements[$0.key]?.z ?? 0) < (placements[$1.key]?.z ?? 0) }
        for (_, v) in ordered { addSubview(v, positioned: .above, relativeTo: nil) }
        if caret.superview != nil { addSubview(caret, positioned: .above, relativeTo: nil) }
    }

    // MARK: paste & drop media

    /// ⌘V: images and photo/video files become stickers at the cursor; anything else pastes as text.
    override func paste(_ sender: Any?) {
        let at = caretFrame().map { NSPoint(x: $0.minX, y: $0.minY) } ?? NSPoint(x: bounds.midX, y: 14)
        if importMedia(from: .general, at: at) { return }
        super.paste(sender)
    }

    /// Dropping images/videos on the page places them where they're dropped.
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let at = convert(info.draggingLocation, from: nil)
        if importMedia(from: info.draggingPasteboard, at: at) { return true }
        return super.performDragOperation(info)
    }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// True if the pasteboard holds an image or a photo/video/audio file.
    static func hasMedia(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: imageTypes) != nil { return true }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { Attachment.kind(for: $0) != nil }
    }

    // A plain-text view only advertises text; add images and files so Paste is enabled and drops are accepted.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + Self.imageTypes + [.fileURL]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.imageTypes + [.fileURL]
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.hasMedia(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        Self.hasMedia(info.draggingPasteboard) ? .copy : super.draggingEntered(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        Self.hasMedia(info.draggingPasteboard) ? .copy : super.draggingUpdated(info)
    }

    /// Reads media from a pasteboard and hands it to the store. Returns false if there wasn't any.
    func importMedia(from pb: NSPasteboard, at point: NSPoint) -> Bool {
        let place = Placement(x: Double(min(max(0, point.x - 20) / max(1, bounds.width), 0.6)),
                              y: Double(max(0, point.y)), width: 0.4, aspect: 0.75, z: (placements.values.map(\.z).max() ?? 0) + 1)
        // 1. files copied in Finder / dragged in
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { Attachment.kind(for: $0) != nil }
        if !urls.isEmpty { onImport(.files(urls), place); return true }
        // 2. raw image data: screenshots, "Copy Image" in a browser, Preview…
        if pb.availableType(from: Self.imageTypes) != nil,
           let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onImport(.image(png), place)
            return true
        }
        return false
    }

    /// Text flows around the stickers.
    private func updateExclusions() {
        let o = textContainerOrigin
        textContainer?.exclusionPaths = stickerViews.values.map { v in
            NSBezierPath(rect: v.frame.offsetBy(dx: -o.x, dy: -o.y).insetBy(dx: -10, dy: -6))
        }
        // TextKit 2 doesn't re-flow on its own when the paths change after layout
        if let tlm = textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
            tlm.textViewportLayoutController.layoutViewport()
        }
        needsDisplay = true
        updateCaret()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        setFrameSize(frame.size)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let top = textContainerInset.height
        if string.isEmpty, let font {
            ("…" as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 6, y: top),
                withAttributes: [.font: font, .foregroundColor: NSColor(Theme.faint)])
        }
    }

    /// Edit ▸ Insert Timestamp (⌘⇧T): drops "[9:04 pm] " at the cursor, like a log line.
    @objc func insertTimestamp(_ sender: Any?) {
        insertText("[\(Clock.time(Date()))] ", replacementRange: selectedRange())
    }
}

/// Media arriving by paste or drop.
enum PastedMedia {
    case files([URL])
    case image(Data)
}

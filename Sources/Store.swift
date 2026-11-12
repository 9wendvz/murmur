import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mood

/// A mood is just an id. 1–5 are the built-in scale (awful … rad); 6+ are emotions the user adds.
/// Saved as a plain number, so files from earlier versions still load.
struct Mood: Hashable, Codable, Identifiable, Comparable {
    let rawValue: Int
    var id: Int { rawValue }

    init?(rawValue: Int) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }
    private init(_ raw: Int) { rawValue = raw }

    static let awful = Mood(1), down = Mood(2), meh = Mood(3), good = Mood(4), rad = Mood(5)
    static let builtIn: [Mood] = [.rad, .good, .meh, .down, .awful]

    var isBuiltIn: Bool { rawValue <= 5 }

    var label: String { FaceStore.shared.style(for: self).label }
    var color: Color { FaceStore.shared.style(for: self).color.color }

    /// Built-in faces best-first, then the user's own emotions in the order they were added.
    static var picker: [Mood] { FaceStore.shared.allMoods }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard raw > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad mood \(raw)"))
        }
        rawValue = raw
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static func < (a: Mood, b: Mood) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Attachments

struct Attachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case photo, video, audio }
    var id = UUID()
    var kind: Kind
    var file: String
    /// When it was added (nil for attachments from before timestamps existed).
    var added: Date? = Date()
    /// Where it sits on the page (photos, videos, drawings). nil = not placed yet; it gets a default spot.
    var place: Placement?
    /// True for doodles drawn in the app: shown without a frame, like ink on the page.
    var isDrawing: Bool?

    var url: URL { DiaryStore.mediaDir.appendingPathComponent(file) }

    static func kind(for url: URL) -> Kind? {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if t.conforms(to: .image) { return .photo }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        return nil
    }
}

/// A sticker's spot on the page. x and width are fractions of the page width, so the layout survives
/// window resizing; y is points from the top of the page, so stickers stay next to the text they belong to.
struct Placement: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    /// height ÷ width of the media, learned when it's first shown.
    var aspect: Double
    var z: Int = 0
    var rotation: Double = 0
}

// MARK: - Entry

struct Entry: Codable, Equatable {
    var mood: Mood?
    var text: String = ""
    var attachments: [Attachment] = []
    /// When the entry was first written (nil for entries saved before timestamps existed).
    var created: Date?
    /// When anything about the entry last changed.
    var updated: Date = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mood = try c.decodeIfPresent(Mood.self, forKey: .mood)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
        created = try c.decodeIfPresent(Date.self, forKey: .created)
    }

    var isEmpty: Bool {
        mood == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
}

// MARK: - Store

final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    @Published private(set) var entries: [String: Entry] = [:]
    /// True between an edit and the moment it's written to disk.
    @Published private(set) var unsaved = false

    let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { keyFormatter.string(from: date) }
    static func date(fromKey key: String) -> Date? { keyFormatter.date(from: key) }

    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Diary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let mediaDir: URL = {
        let dir = directory.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        fileURL = Self.directory.appendingPathComponent("entries.json")
        load()
    }

    /// Set when entries.json existed but couldn't be read; saving is then blocked so it's never overwritten.
    private(set) var loadFailed = false

    static var backupDir: URL {
        let d = directory.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }   // first launch: nothing to load
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = Self.resizeOldDrawings(try decoder.decode([String: Entry].self, from: data))
            backUp(data)
        } catch {
            // Never start from an empty diary and overwrite the real one: keep the file aside and stop saving.
            loadFailed = true
            let aside = Self.backupDir.appendingPathComponent("entries-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: aside)
            NSLog("Diary: couldn't read entries.json (\(error)); kept a copy at \(aside.path) and disabled saving")
        }
    }

    /// Drawings placed before they had their own sizing got the photo width, which made square doodles
    /// about twice as tall as photos. Shrinks those (only ones still at that exact old default width — anything
    /// resized by hand is left alone) without touching the entry's edit time.
    static func resizeOldDrawings(_ entries: [String: Entry]) -> [String: Entry] {
        var out = entries
        for (k, e) in entries {
            for (i, a) in e.attachments.enumerated() where a.isDrawing == true {
                guard var p = a.place, abs(p.width - 0.38) < 0.0001,
                      let (w, asp) = NotebookTextView.drawingSize(a, pageWidth: EntryEditor.pageWidth), w < p.width else { continue }
                p.width = w; p.aspect = asp
                out[k]!.attachments[i].place = p
            }
        }
        return out
    }

    /// Keeps the last 20 launch-time copies of entries.json.
    private func backUp(_ data: Data) {
        guard data.count > 4 else { return }     // skip empty "{}"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = Self.backupDir.appendingPathComponent("entries-\(f.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
        let old = ((try? FileManager.default.contentsOfDirectory(at: Self.backupDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("entries-2") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(20)
        for u in old { try? FileManager.default.removeItem(at: u) }
    }

    func saveNow() {
        pendingSave?.cancel()
        if unsaved { unsaved = false }
        guard !loadFailed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        if !unsaved { unsaved = true }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func entry(for date: Date) -> Entry? { entries[Self.key(date)] }

    private func mutate(_ date: Date, _ change: (inout Entry) -> Void) {
        let k = Self.key(date)
        var e = entries[k] ?? Entry()
        change(&e)
        let now = Date()
        if e.created == nil { e.created = entries[k]?.updated ?? now }
        e.updated = now
        entries[k] = e.isEmpty ? nil : e
        scheduleSave()
    }

    func setMood(_ mood: Mood?, for date: Date) {
        undoable(date, mood == nil ? "Clear Mood" : "Mood")
        mutate(date) { $0.mood = mood }
    }

    /// Text isn't registered here: the page's text view keeps its own (finer-grained) undo for typing.
    func setText(_ text: String, for date: Date) { mutate(date) { $0.text = text } }

    func addAttachment(_ a: Attachment, for date: Date) {
        undoable(date, a.kind == .video ? "Add Video" : a.kind == .audio ? "Add Voice Memo" : "Add Photo")
        mutate(date) { $0.attachments.append(a) }
    }

    func setPlacement(_ p: Placement, of id: UUID, for date: Date) {
        undoable(date, "Move")
        mutate(date) { e in
            if let i = e.attachments.firstIndex(where: { $0.id == id }) { e.attachments[i].place = p }
        }
    }

    func removeAttachment(_ a: Attachment, for date: Date) {
        undoable(date, "Remove")
        mutate(date) { $0.attachments.removeAll { $0.id == a.id } }
        Self.trash(a.file)        // kept until next launch so Undo can bring it back
    }

    // MARK: undo

    /// The main window's undo manager (shared with the text view, so ⌘Z / ctrl-Z walks one history).
    weak var undoManager: UndoManager?

    /// Removed media waits here until the next launch.
    static var trashDir: URL {
        let d = mediaDir.appendingPathComponent(".trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func trash(_ file: String) {
        try? FileManager.default.moveItem(at: mediaDir.appendingPathComponent(file), to: trashDir.appendingPathComponent(file))
    }

    static func untrash(_ file: String) {
        try? FileManager.default.moveItem(at: trashDir.appendingPathComponent(file), to: mediaDir.appendingPathComponent(file))
    }

    static func emptyTrash() { try? FileManager.default.removeItem(at: trashDir) }

    /// Records the day's mood + attachments as they are now, so the next change can be undone.
    private func undoable(_ date: Date, _ name: String) {
        guard let um = undoManager else { return }
        let k = Self.key(date)
        let before = entries[k]
        um.registerUndo(withTarget: self) { s in s.restore(k, mood: before?.mood, attachments: before?.attachments ?? [], name: name) }
        um.setActionName(name)
    }

    /// Puts back a day's mood and attachments (leaving its text alone), moving media files in/out of the
    /// trash to match, and registers the reverse so Redo works.
    func restore(_ k: String, mood: Mood?, attachments: [Attachment], name: String) {
        let current = entries[k]
        let now = Set(current?.attachments.map(\.file) ?? []), then = Set(attachments.map(\.file))
        for f in then.subtracting(now) { Self.untrash(f) }
        for f in now.subtracting(then) { Self.trash(f) }

        var e = current ?? Entry()
        e.mood = mood
        e.attachments = attachments
        e.updated = Date()
        entries[k] = e.isEmpty ? nil : e
        scheduleSave()

        undoManager?.registerUndo(withTarget: self) { s in
            s.restore(k, mood: current?.mood, attachments: current?.attachments ?? [], name: name)
        }
        undoManager?.setActionName(name)
    }

    /// Copies photos / videos / audio files into the diary and attaches them. Returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL], for date: Date, at place: Placement? = nil) -> Int {
        var added = 0
        for src in urls {
            guard let kind = Attachment.kind(for: src) else { continue }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let name = UUID().uuidString + "." + src.pathExtension.lowercased()
            do {
                try FileManager.default.copyItem(at: src, to: Self.mediaDir.appendingPathComponent(name))
                var a = Attachment(kind: kind, file: name)
                if kind != .audio, var p = place {
                    p.y += Double(added) * 24; p.x = min(0.6, p.x + Double(added) * 0.03)   // fan out several at once
                    a.place = p
                }
                addAttachment(a, for: date)
                added += 1
            } catch { continue }
        }
        return added
    }

    /// Saves pasted image data (a screenshot, an image copied from a browser…) as a photo sticker.
    func importImage(_ png: Data, for date: Date, at place: Placement?) {
        let name = UUID().uuidString + ".png"
        guard (try? png.write(to: Self.mediaDir.appendingPathComponent(name), options: .atomic)) != nil else { return }
        var a = Attachment(kind: .photo, file: name)
        a.place = place
        addAttachment(a, for: date)
    }

    /// Clears a mood from every day that used it (when a custom emotion is deleted).
    func clearMood(_ mood: Mood) {
        for (k, e) in entries where e.mood == mood {
            var e = e
            e.mood = nil
            entries[k] = e.isEmpty ? nil : e
        }
        scheduleSave()
    }

    func moods(inMonthOf month: Date) -> [Mood] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month),
              let start = cal.date(from: cal.dateComponents([.year, .month], from: month)) else { return [] }
        return range.compactMap { d in
            entry(for: cal.date(byAdding: .day, value: d - 1, to: start)!)?.mood
        }
    }
}

// MARK: - Navigation shared between the window and the widget

final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published var selected: Date = Date()
    @Published var month: Date = Date()
    @Published var editingFaces = false
    @Published var showingInsights = false
    @Published var searching = false
    @Published var todo = false
    @Published var showingDates = false
    /// Pre-fills the date when adding an important date from the calendar.
    var dateDraft: Date?
    @Published var feed = false

    func step(days n: Int) {
        let cal = Calendar.current
        guard let d = cal.date(byAdding: .day, value: n, to: selected),
              d <= Date() || cal.isDateInToday(d) else { return }
        selected = d
        month = d
    }

    func goToToday() {
        selected = Date()
        month = Date()
    }
}

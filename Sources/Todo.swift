import SwiftUI

// MARK: - Model

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// "yyyy-MM-dd", or nil for no due date.
    var due: String?
    var created = Date()
    var done: Date?

    var isDone: Bool { done != nil }

    /// Days until due (negative = overdue), relative to `today`.
    func daysLeft(from today: Date = Date(), calendar cal: Calendar = .current) -> Int? {
        guard let due, let d = DiaryStore.date(fromKey: due) else { return nil }
        return cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: d)).day
    }

    /// Pulls a date out of what was typed: "essay due friday" → ("essay due", friday).
    static func parse(_ text: String, now: Date = Date()) -> (title: String, due: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "due friday" makes the detector return *today*; blank out "due" (same length, so ranges still line up)
        let probe = trimmed.replacingOccurrences(of: #"\bdue\b"#, with: "   ", options: [.regularExpression, .caseInsensitive])
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)),
              let date = match.date, let r = Range(match.range, in: trimmed) else { return (trimmed, nil) }
        var title = trimmed
        title.removeSubrange(r)
        title = title.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "@,-–:")))
        // drop a dangling "due"/"by"/"on"/"at" left behind by the date phrase: "essay due friday" → "essay"
        var trimmedTail = true
        while trimmedTail {
            trimmedTail = false
            for tail in [" due", " by", " on", " at"] where title.lowercased().hasSuffix(tail) {
                title.removeLast(tail.count); trimmedTail = true
            }
        }
        return (title.isEmpty ? trimmed : title, date)
    }

    /// Open first (overdue, then soonest due, then undated oldest-first); done last, most recent first.
    static func sorted(_ items: [TodoItem], today: Date = Date()) -> [TodoItem] {
        items.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.isDone { return (a.done ?? .distantPast) > (b.done ?? .distantPast) }
            switch (a.daysLeft(from: today), b.daysLeft(from: today)) {
            case let (x?, y?): return x != y ? x < y : a.created < b.created
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.created < b.created
            }
        }
    }
}

// MARK: - Store

final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = []
    private let fileURL = DiaryStore.directory.appendingPathComponent("todo.json")

    init() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let decoded = try? d.decode([TodoItem].self, from: data) { items = decoded }
    }

    var open: Int { items.filter { !$0.isDone }.count }
    var overdue: Int { items.filter { !$0.isDone && ($0.daysLeft() ?? 0) < 0 }.count }
    func due(on day: Date) -> [TodoItem] { items.filter { !$0.isDone && $0.due == DiaryStore.key(day) } }

    weak var undoManager: UndoManager?

    private func undoable(_ name: String) {
        let before = items
        undoManager?.registerUndo(withTarget: self) { s in s.restore(before, name) }
        undoManager?.setActionName(name)
    }

    private func restore(_ snapshot: [TodoItem], _ name: String) {
        let current = items
        items = snapshot
        save()
        undoManager?.registerUndo(withTarget: self) { s in s.restore(current, name) }
        undoManager?.setActionName(name)
    }

    func add(_ text: String) {
        let (title, due) = TodoItem.parse(text)
        guard !title.isEmpty else { return }
        undoable("Add Task")
        items.append(TodoItem(title: title, due: due.map(DiaryStore.key)))
        save()
    }

    func toggle(_ t: TodoItem) { undoable(t.isDone ? "Untick Task" : "Tick Task"); update(t) { $0.done = $0.done == nil ? Date() : nil } }
    func setDue(_ t: TodoItem, _ day: Date?) { undoable("Change Due Date"); update(t) { $0.due = day.map(DiaryStore.key) } }
    func rename(_ t: TodoItem, _ title: String) { undoable("Rename Task"); update(t) { $0.title = title } }
    func remove(_ t: TodoItem) { undoable("Delete Task"); items.removeAll { $0.id == t.id }; save() }
    func clearDone() { undoable("Clear Done"); items.removeAll(where: \.isDone); save() }

    private func update(_ t: TodoItem, _ change: (inout TodoItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == t.id }) else { return }
        change(&items[i])
        save()
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]
        if let data = try? e.encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Panel

struct TodoPanel: View {
    @ObservedObject private var todo = TodoStore.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let sorted = TodoItem.sorted(todo.items)
        let open = sorted.filter { !$0.isDone }
        let done = sorted.filter(\.isDone)

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("~/diary/todo")
                Text("\(open.count)").foregroundStyle(Theme.faint).contentTransition(.numericText())
                Spacer()
            }
            .font(Theme.font(13))

            HStack(spacing: 8) {
                Text(">").foregroundStyle(Theme.amber)
                TextField("add a task… (try \"essay due friday\")", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { todo.add(draft) }
                        draft = ""
                    }
            }
            .font(Theme.font(12))
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if open.isEmpty && done.isEmpty {
                        Text("nothing to do. nice.").foregroundStyle(Theme.faint).padding(.top, 6)
                    }
                    ForEach(open) { row($0).transition(.opacity.combined(with: .move(edge: .top))) }
                    if !done.isEmpty {
                        HStack {
                            Text("done · \(done.count)")
                            Rectangle().fill(Theme.line).frame(height: 1)
                            Button("[clear]") { withAnimation(.easeOut(duration: 0.25)) { todo.clearDone() } }
                                .buttonStyle(TextButtonStyle())
                        }
                        .font(Theme.font(9))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 18).padding(.bottom, 4)
                        ForEach(done) { row($0).transition(.opacity) }
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: todo.items)
            }
        }
        .font(Theme.font(12))
        .onAppear { focused = true }
    }

    private func row(_ t: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { todo.toggle(t) } label: {
                Text(t.isDone ? "[x]" : "[ ]").foregroundStyle(t.isDone ? Theme.green : Theme.sub)
            }
            .buttonStyle(.plain)
            Text(t.title)
                .strikethrough(t.isDone, color: Theme.faint)
                .foregroundStyle(t.isDone ? Theme.faint : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            dueLabel(t)
        }
        .font(Theme.font(12))
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Due Today") { todo.setDue(t, Date()) }
            Button("Due Tomorrow") { todo.setDue(t, Calendar.current.date(byAdding: .day, value: 1, to: Date())) }
            Button("Due Next Week") { todo.setDue(t, Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
            Button("No Due Date") { todo.setDue(t, nil) }
            Divider()
            Button("Delete", role: .destructive) { withAnimation(.easeOut(duration: 0.2)) { todo.remove(t) } }
        }
    }

    @ViewBuilder private func dueLabel(_ t: TodoItem) -> some View {
        if t.isDone, let d = t.done {
            Text(Clock.time(d)).foregroundStyle(Theme.line).font(Theme.font(9))
        } else if let n = t.daysLeft() {
            Text(n < 0 ? "\(-n)d late" : n == 0 ? "today" : n == 1 ? "tmrw" : "\(n)d")
                .font(Theme.font(10))
                .foregroundStyle(n <= 0 ? Theme.amber : Theme.faint)
                .monospacedDigit()
        }
    }
}

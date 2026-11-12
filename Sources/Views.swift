import SwiftUI
import AppKit

private let ease = Animation.easeOut(duration: 0.28)

// MARK: - Main window

struct MainView: View {
    @ObservedObject var nav = AppNav.shared
    @State private var booted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CalendarPane().frame(width: 330)
                Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 40)
                ZStack {
                    if nav.feed && !nav.searching {
                        FeedView().transition(.opacity.combined(with: .offset(y: 8)))
                    } else {
                        EntryEditor().transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.28), value: nav.feed)
            }
            StatusBar()
        }
        .overlay {
            if !booted { BootScreen(done: $booted).transition(.opacity) }
        }
        // left panel 330 + divider + page column + margins
        .frame(minWidth: 330 + 1 + EntryEditor.pageWidth + 88, minHeight: 560)
        .background { ZStack { Theme.paper; PerfBoard() } }
        .foregroundStyle(Theme.ink)
        .font(Theme.font(12))
        .tint(Theme.ink)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $nav.editingFaces) { FaceEditor() }
        .sheet(isPresented: $nav.showingInsights) { InsightsView() }
        .sheet(isPresented: $nav.showingDates) { DatesSheet() }
    }

}

// MARK: - Calendar

struct CalendarPane: View {
    @ObservedObject var store = DiaryStore.shared
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var faces = FaceStore.shared
    @State private var direction = 1
    @State private var pager = WheelPager()
    @ObservedObject var dates = DatesStore.shared

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var monthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: nav.month))!
    }

    private var cells: [Date?] {
        let lead = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: monthStart)!.count
        return Array(repeating: nil, count: lead) +
            (0..<days).map { cal.date(byAdding: .day, value: $0, to: monthStart)! }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            panes
            VStack(alignment: .leading, spacing: 14) {
                ModeSwitch()
                HStack(spacing: 16) {
                    Button { nav.editingFaces = true } label: { HStack(spacing: 6) { Text("[faces]"); Keycap(key: "⌘,") } }
                    Button { nav.showingInsights = true } label: { HStack(spacing: 6) { Text("[insights]"); Keycap(key: "⌘I") } }
                    Button { nav.showingDates = true } label: { HStack(spacing: 6) { Text("[dates]"); Keycap(key: "⌘D") } }
                }
                .buttonStyle(TextButtonStyle())
            }
        }
        .overlay(alignment: .topLeading) {
            PanelLabel(number: "01", name: nav.searching ? "search" : nav.todo ? "todo" : "cal")
                .offset(y: -24)
                .animation(nil, value: nav.feed)
        }
        .padding(.horizontal, 30)
        .padding(.top, 48)
        .padding(.bottom, 26)
        .overlay(CornerMarks(inset: 14))
    }

    private var panes: some View {
        ZStack(alignment: .topLeading) {
            if nav.searching {
                SearchPanel()
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else if nav.todo {
                TodoPanel()
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                calendar
                    .transition(.opacity)
                    .onHover { pager.hovering = $0 }
                    .onAppear { pager.start { n in shift(n) } }
                    .onDisappear { pager.stop() }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 14) {
                Text(String(format: "%04d.%02d", cal.component(.year, from: monthStart), cal.component(.month, from: monthStart)))
                    .contentTransition(.numericText(countsDown: direction < 0))
                    .onTapGesture(count: 2) { withAnimation(ease) { nav.goToToday() } }
                    .help("double-click for today")
                Spacer()
                Button("[‹]") { shift(-1) }.buttonStyle(TextButtonStyle())
                Button("[›]") { shift(1) }.buttonStyle(TextButtonStyle())
            }
            .font(Theme.font(13))

            VStack(spacing: 14) {
                HStack(spacing: 4) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                        Text(s.lowercased()).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                    }
                }
                ZStack {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                            if let day { dayCell(day) } else { Color.clear.frame(height: 34) }
                        }
                    }
                    .id(monthStart)
                    .transition(.asymmetric(
                        insertion: .offset(x: CGFloat(direction) * 24).combined(with: .opacity),
                        removal: .opacity))
                }
            }
            .font(Theme.font(11))

            Spacer()
        }
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortWeekdaySymbols
        let i = cal.firstWeekday - 1
        return Array(s[i...] + s[..<i])
    }

    private func shift(_ n: Int) {
        direction = n
        withAnimation(ease) { nav.month = cal.date(byAdding: .month, value: n, to: monthStart)! }
    }

    @ViewBuilder private func dayCell(_ day: Date) -> some View {
        let isFuture = day > Date() && !cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: nav.selected)
        let isToday = cal.isDateInToday(day)
        let entry = store.entry(for: day)
        let important = dates.on(day)

        VStack(spacing: 4) {
            ZStack {
                if let mood = entry?.mood {
                    MoodFace(mood: mood, size: 26)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Text("\(cal.component(.day, from: day))")
                        .foregroundStyle(isToday ? Theme.red : isFuture ? Theme.faint : Theme.sub)
                        .transition(.opacity)
                }
            }
            .frame(height: 26)
            // underline marks the selected day; a dot marks words/media without a mood
            Rectangle()
                .fill(isSelected ? Theme.ink : (entry?.mood == nil && entry?.hasContent == true ? Theme.faint : .clear))
                .frame(width: isSelected ? 12 : 3, height: 1)
        }
        .frame(height: 34)
        .overlay(alignment: .top) {
            if !important.isEmpty {
                Text("◆").font(.system(size: 6)).foregroundStyle(Theme.amber).offset(x: 14, y: -2)
            }
        }
        .help(([entry?.mood.map { faces.style(for: $0).label }].compactMap { $0 } + important.map { "◆ " + $0.title }).joined(separator: "\n"))
        .contentShape(Rectangle())
        .onTapGesture { if !isFuture { withAnimation(ease) { nav.selected = day } } }
        .contextMenu {
            Button("Add Important Date…") { nav.dateDraft = day; nav.showingDates = true }
        }
    }
}

// MARK: - Entry

struct EntryEditor: View {
    @ObservedObject var store = DiaryStore.shared
    @ObservedObject var nav = AppNav.shared
    @ObservedObject var faces = FaceStore.shared
    @ObservedObject var recorder = VoiceRecorder.shared
    @ObservedObject var todo = TodoStore.shared
    @ObservedObject var dates = DatesStore.shared

    @State private var viewing: Attachment?
    @State private var doodling = false
    @State private var shooting = false
    @State private var adding = false
    @State private var dropTargeted = false

    /// Width of the writing column (header, page and footer).
    static let pageWidth: CGFloat = 600

    private var date: Date { nav.selected }
    private var entry: Entry? { store.entry(for: date) }
    private var visuals: [Attachment] { entry?.attachments.filter { $0.kind != .audio } ?? [] }
    private var voices: [Attachment] { entry?.attachments.filter { $0.kind == .audio } ?? [] }
    private var wordCount: Int { (entry?.text ?? "").split(whereSeparator: { $0.isWhitespace }).count }
    private var charCount: Int { (entry?.text ?? "").count }
    /// "written 9:04 pm · edited 11:10 pm" (dates shown when it wasn't the same day).
    static func timestamps(_ e: Entry, day: Date) -> String {
        let cal = Calendar.current
        func t(_ d: Date) -> String {
            let hm = Clock.time(d)
            if cal.isDate(d, inSameDayAs: day) { return hm }
            return String(format: "%02d.%02d ", cal.component(.month, from: d), cal.component(.day, from: d)) + hm
        }
        let written = e.created ?? e.updated
        var s = "written " + t(written)
        if e.updated.timeIntervalSince(written) > 60 { s += " · edited " + t(e.updated) }
        return s
    }

    private var isoDate: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                page
                    .id(DiaryStore.key(date))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        // A fixed page width, like real paper: resizing the window only changes the margins, so text wraps
        // at the same places and stickers stay exactly where they were put.
        .frame(width: Self.pageWidth)
        .overlay(alignment: .topLeading) {
            PanelLabel(number: "02", name: "entry").offset(y: -24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 48)
        .padding(.bottom, 26)
        .overlay(CornerMarks(inset: 14))
        .overlay {
            if dropTargeted {
                Rectangle().stroke(Theme.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .padding(14).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            withAnimation(ease) { store.importFiles(urls, for: date) > 0 }
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $viewing) { MediaViewer(attachment: $0) }
        .sheet(isPresented: $doodling) { DoodleSheet(date: date) }
        .sheet(isPresented: $shooting) { CameraSheet(date: date) }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("~/diary/\(isoDate).txt")
                        .font(Theme.font(10))
                        .foregroundStyle(Theme.faint)
                    HStack(spacing: 0) {
                        Text(String(format: "%02d.%02d", Calendar.current.component(.month, from: date), Calendar.current.component(.day, from: date))
                             + "  " + date.formatted(.dateTime.weekday(.abbreviated)).lowercased())
                            .font(Theme.font(13))
                    }
                    if let entry {
                        Text(Self.timestamps(entry, day: date))
                            .font(Theme.font(10))
                            .foregroundStyle(Theme.faint)
                            .contentTransition(.opacity)
                    }
                    ForEach(DatesStore.shared.on(date)) { d in
                        Text("◆ " + d.title).font(Theme.font(11)).foregroundStyle(Theme.amber)
                    }
                    ForEach(todo.due(on: date)) { t in
                        Button { withAnimation(.easeOut(duration: 0.2)) { todo.toggle(t) } } label: {
                            Text("[ ] " + t.title).font(Theme.font(11))
                        }
                        .buttonStyle(TextButtonStyle())
                        .help("due today · click to tick off")
                    }
                }
                Spacer()
                StatusLight(unsaved: store.unsaved)
            }

            HStack(alignment: .center, spacing: 22) {
                moodPicker
                Text("mood: " + (entry?.mood.map { faces.style(for: $0).label.isEmpty ? "untitled" : faces.style(for: $0).label } ?? "—"))
                    .font(Theme.font(11))
                    .foregroundStyle(entry?.mood == nil ? Theme.faint : Theme.sub)
                    .contentTransition(.opacity)
                    .animation(ease, value: entry?.mood)
                suggestion
            }

            // the notebook sheet
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("disp.01")
                    Text("utf-8 · lf")
                    Text("\((entry?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).count) ln")
                        .monospacedDigit()
                    Spacer()
                    Text("autosave")
                    LED(on: !store.unsaved, color: store.unsaved ? Theme.amber : Theme.green)
                }
                .font(Theme.font(8))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                NotebookEditor(
                    text: entry?.text ?? "",
                    onChange: { store.setText($0, for: date) },
                    stickers: visuals,
                    onPlace: { id, p in store.setPlacement(p, of: id, for: date) },
                    onOpen: { viewing = $0 },
                    onRemove: { a in withAnimation(ease) { store.removeAttachment(a, for: date) } },
                    onImport: { media, place in
                        switch media {
                        case .files(let urls): store.importFiles(urls, for: date, at: place)
                        case .image(let png): store.importImage(png, for: date, at: place)
                        }
                    })
                    .frame(maxHeight: .infinity)

                // voice memos stay put in a row along the bottom of the page
                if !voices.isEmpty {
                    Rectangle().fill(Theme.rule).frame(height: 1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(voices) { a in
                                VoiceChip(attachment: a)
                                    .overlay(alignment: .bottomLeading) { addedTime(a).offset(y: 16) }
                                    .padding(.horizontal, 6)
                                    .contextMenu { removeButton(a) }
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 22).padding(.vertical, 12)
                    }
                    .transition(.opacity)
                }
            }
            .background(Theme.card)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            .screwed()
            .shadow(color: Color(red: 0.35, green: 0.25, blue: 0.1).opacity(0.10), radius: 8, y: 3)
        }
    }

    /// When no mood is picked yet, offer one based on how the writing sounds (on-device NLP).
    @ViewBuilder private var suggestion: some View {
        if entry?.mood == nil, let m = Sentiment.suggestedMood(for: entry?.text ?? "") {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { store.setMood(m, for: date) }
            } label: {
                HStack(spacing: 6) {
                    Text("sounds")
                    MoodFace(mood: m, size: 14)
                    Text(faces.style(for: m).label + "? [use]")
                }
            }
            .buttonStyle(TextButtonStyle())
            .font(Theme.font(11))
            .help("suggested from the tone of your writing, analysed on this mac")
            .transition(.opacity.combined(with: .offset(x: -6)))
        }
    }

    private var moodPicker: some View {
        HStack(spacing: 16) {
            ForEach(Mood.picker) { m in
                let on = entry?.mood == m
                MoodFace(mood: m, size: 36)
                    .scaleEffect(on ? 1.12 : 1)
                    .opacity(entry?.mood == nil || on ? 1 : 0.22)
                    .contentShape(Circle())
                    .help(faces.style(for: m).label)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            store.setMood(on ? nil : m, for: date)
                        }
                    }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            if recorder.isRecording {
                Button {
                    withAnimation(ease) { recorder.toggle(for: date) }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.red).frame(width: 5, height: 5)
                        Text(formatDuration(recorder.elapsed)).monospacedDigit()
                        Text("[stop]")
                    }
                }
                .buttonStyle(TextButtonStyle(active: true))
                .transition(.opacity)
            } else {
                Button(adding ? "[×]" : "[+]") { withAnimation(ease) { adding.toggle() } }
                    .buttonStyle(TextButtonStyle())
                if adding {
                    Group {
                        Button("[camera]") { adding = false; shooting = true }
                        Button("[photo]") { adding = false; MediaPicker.pick(for: date) }
                        Button("[voice]") { withAnimation(ease) { adding = false; recorder.toggle(for: date) } }
                        Button("[draw]") { adding = false; doodling = true }
                    }
                    .buttonStyle(TextButtonStyle())
                    .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            Spacer()
            Text("\(wordCount) words · \(charCount) chars")
                .font(Theme.font(11).monospacedDigit())
                .foregroundStyle(Theme.faint)
                .contentTransition(.numericText())
        }
        .frame(height: 20)
        .padding(.top, 16)
    }

    /// Tiny "9:04 pm" stamp showing when an attachment was added.
    @ViewBuilder private func addedTime(_ a: Attachment) -> some View {
        if let d = a.added {
            Text(Clock.time(d))
                .font(Theme.font(8))
                .foregroundStyle(a.kind == .audio ? Theme.faint : .white)
                .shadow(color: .black.opacity(a.kind == .audio ? 0 : 0.5), radius: 1)
                .padding(3)
        }
    }

    @ViewBuilder private func removeButton(_ a: Attachment) -> some View {
        Button("Copy") { MediaClipboard.copy(a) }
        Button("Remove", role: .destructive) {
            if AudioPlayback.shared.playing == a.id { AudioPlayback.shared.stop() }
            withAnimation(ease) { store.removeAttachment(a, for: date) }
        }
    }
}

/// A tiny square indicator light: amber while there are unsaved changes, green once written to disk.
struct StatusLight: View {
    let unsaved: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1)
                .fill(unsaved ? Theme.amber : Theme.green)
                .frame(width: 6, height: 6)
                .shadow(color: (unsaved ? Theme.amber : Theme.green).opacity(0.8), radius: pulse ? 4 : 1.5)
            Text(unsaved ? "writing" : "saved")
                .font(Theme.font(10))
                .foregroundStyle(Theme.faint)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: unsaved)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// One thin line along the bottom of the window: what you'd see on a little handheld terminal.
struct StatusBar: View {
    @ObservedObject private var store = DiaryStore.shared
    @ObservedObject private var dates = DatesStore.shared
    @ObservedObject private var todo = TodoStore.shared
    @ObservedObject private var faces = FaceStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let cal = Calendar.current
            let day = cal.ordinality(of: .day, in: .year, for: ctx.date) ?? 0
            let days = cal.range(of: .day, in: .year, for: ctx.date)?.count ?? 365
            HStack(spacing: 18) {
                Text("diary.os").foregroundStyle(Theme.sub)
                Text("\(store.entries.count) \(store.entries.count == 1 ? "entry" : "entries")")
                Text("\(faces.allMoods.count) moods")
                Text("local").padding(.horizontal, 5).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                Spacer()
                if todo.open > 0 {
                    Text("[ ] \(todo.open)" + (todo.overdue > 0 ? " · \(todo.overdue) late" : ""))
                        .foregroundStyle(todo.overdue > 0 ? Theme.amber : Theme.faint)
                }
                if let (d, when) = dates.next(from: ctx.date) {
                    let days = cal.dateComponents([.day], from: cal.startOfDay(for: ctx.date), to: when).day ?? 0
                    Text("◆ \(d.title) " + (days == 0 ? "today" : "in \(days)d"))
                        .foregroundStyle(days <= 3 ? Theme.amber : Theme.faint)
                        .lineLimit(1)
                }
                if let bat = Battery.label() { Text(bat) }
                Text("d\(day)/\(days)")
                // a year-progress bar made of characters
                Text(progress(Double(day) / Double(days)))
                Text(Clock.timeWithSeconds(ctx.date))
                    .monospacedDigit()
            }
            .font(Theme.font(10))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 18)
            .frame(height: 24)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private func progress(_ f: Double) -> String {
        let n = 12, filled = Int((f * Double(n)).rounded())
        return "[" + String(repeating: "■", count: filled) + String(repeating: "·", count: n - filled) + "]"
    }
}


/// Turns scroll-wheel / trackpad movement over the calendar into month changes.
final class WheelPager {
    var hovering = false
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var lastFlip = Date.distantPast

    func start(_ flip: @escaping (Int) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.hovering else { return e }
            let d = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX
            if e.phase == .began { self.accumulated = 0 }
            self.accumulated += e.hasPreciseScrollingDeltas ? d : d * 12
            // one month per deliberate gesture: a threshold plus a short cooldown
            if abs(self.accumulated) > 40, Date().timeIntervalSince(self.lastFlip) > 0.35 {
                flip(self.accumulated < 0 ? 1 : -1)
                self.accumulated = 0
                self.lastFlip = Date()
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

import SwiftUI

/// Every day as a post, newest first, in one long scroll: face, date, photos/videos you can swipe through,
/// your writing as the caption, and voice memos. Stays in sync with the calendar both ways.
struct FeedView: View {
    @ObservedObject private var store = DiaryStore.shared
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var faces = FaceStore.shared

    @State private var topID: String?
    @State private var viewing: Attachment?
    @State private var scrolledByFeed = false

    private let postWidth: CGFloat = 470
    private let cal = Calendar.current

    /// Rows: a month header ("m-2026-11") followed by that month's days ("2026-11-12"), newest first.
    private var rows: [String] {
        var out: [String] = []
        var month = ""
        for k in store.entries.keys.sorted(by: >) {
            let m = String(k.prefix(7))
            if m != month { out.append("m-" + m); month = m }
            out.append(k)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.entries.isEmpty {
                Spacer()
                Text("no memories yet.").foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 30) {
                            ForEach(rows, id: \.self) { id in
                                Group {
                                    if id.hasPrefix("m-") { monthHeader(String(id.dropFirst(2))) } else { post(id) }
                                }
                                .id(id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollPosition(id: $topID, anchor: .top)
                    // scrolling the feed moves the calendar along
                    .onChange(of: topID) { _, id in
                        guard let id, !id.hasPrefix("m-"), let d = DiaryStore.date(fromKey: id),
                              !cal.isDate(d, inSameDayAs: nav.selected) else { return }
                        scrolledByFeed = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            nav.selected = d
                            nav.month = d
                        }
                    }
                    // clicking a day in the calendar scrolls the feed to it
                    .onChange(of: nav.selected) { _, d in
                        if scrolledByFeed { scrolledByFeed = false; return }
                        let k = DiaryStore.key(d)
                        if store.entries[k] != nil { withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(k, anchor: .top) } }
                    }
                    .onAppear {
                        let k = DiaryStore.key(nav.selected)
                        if store.entries[k] != nil { proxy.scrollTo(k, anchor: .top) }
                    }
                }
            }
        }
        .font(Theme.font(12))
        .overlay(alignment: .topLeading) { PanelLabel(number: "02", name: "feed").offset(x: 44, y: -24) }
        .padding(.top, 48)
        .overlay(CornerMarks(inset: 14))
        .sheet(item: $viewing) { MediaViewer(attachment: $0) }
    }

    private func monthHeader(_ m: String) -> some View {
        let count = store.entries.keys.filter { $0.hasPrefix(m) }.count
        return HStack(spacing: 10) {
            Text(m.replacingOccurrences(of: "-", with: "."))
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("\(count) \(count == 1 ? "memory" : "memories")")
        }
        .font(Theme.font(10))
        .foregroundStyle(Theme.faint)
        .frame(width: postWidth)
        .padding(.top, 6)
    }

    // MARK: a post

    @ViewBuilder private func post(_ key: String) -> some View {
        if let e = store.entries[key], let day = DiaryStore.date(fromKey: key) {
            let visuals = e.attachments.filter { $0.kind != .audio }
            let voices = e.attachments.filter { $0.kind == .audio }
            VStack(alignment: .leading, spacing: 0) {
                // header
                HStack(spacing: 10) {
                    MoodFace(mood: e.mood, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.mood.map { faces.style(for: $0).label } ?? "—").font(Theme.font(12))
                        Text(EntryEditor.timestamps(e, day: day)).font(Theme.font(9)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text(String(format: "%02d.%02d", cal.component(.month, from: day), cal.component(.day, from: day))
                         + " " + day.formatted(.dateTime.weekday(.abbreviated)).lowercased())
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.sub)
                }
                .padding(14)

                if !visuals.isEmpty {
                    Carousel(items: visuals, width: postWidth) { viewing = $0 }
                }

                VStack(alignment: .leading, spacing: 12) {
                    if !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Caption(text: e.text)
                    }
                    if !voices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) { ForEach(voices) { VoiceChip(attachment: $0) } }
                    }
                    HStack {
                        Text(key).font(Theme.font(8)).foregroundStyle(Theme.line)
                        Spacer()
                        Button("[open]") {
                            withAnimation(.easeOut(duration: 0.28)) { nav.selected = day; nav.month = day; nav.feed = false }
                        }
                        .buttonStyle(TextButtonStyle())
                        .font(Theme.font(10))
                    }
                }
                .padding(14)
            }
            .frame(width: postWidth)
            .background(Theme.card)
            .overlay(Rectangle().stroke(DiaryStore.key(nav.selected) == key ? Theme.faint : Theme.line, lineWidth: 1))
            .shadow(color: Color(red: 0.35, green: 0.25, blue: 0.1).opacity(0.08), radius: 6, y: 2)
        }
    }
}

/// Swipe through a post's photos and videos, with a "2/3" counter and arrows.
private struct Carousel: View {
    let items: [Attachment]
    let width: CGFloat
    let open: (Attachment) -> Void
    @State private var page: UUID?

    private var index: Int { items.firstIndex { $0.id == page } ?? 0 }
    /// Posts with only doodles don't need a big square photo frame.
    private var height: CGFloat { items.allSatisfy { $0.isDrawing == true } ? width * 0.5 : width }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { a in
                        FeedMedia(attachment: a, width: width, height: height)
                            .onTapGesture { open(a) }
                            .contextMenu { Button("Copy") { MediaClipboard.copy(a) } }
                            .id(a.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .frame(width: width, height: height)

            if items.count > 1 {
                HStack(spacing: 10) {
                    Button("‹") { go(-1) }.disabled(index == 0)
                    Text("\(index + 1)/\(items.count)").monospacedDigit()
                    Button("›") { go(1) }.disabled(index == items.count - 1)
                }
                .buttonStyle(.plain)
                .font(Theme.font(10))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(10)
            }
        }
        .onAppear { page = items.first?.id }
    }

    private func go(_ n: Int) {
        let i = min(max(0, index + n), items.count - 1)
        withAnimation(.easeOut(duration: 0.3)) { page = items[i].id }
    }
}

/// A square, full-width photo or video frame for the feed.
private struct FeedMedia: View {
    let attachment: Attachment
    let width: CGFloat
    var height: CGFloat? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(attachment.isDrawing == true ? Theme.card : Theme.paperDeep)
            if let image {
                if attachment.isDrawing == true {
                    // a doodle sits on the page at about the size it was drawn, like ink, instead of filling the frame
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: min(width * 0.6, image.size.width / 2 * 1.5),
                               maxHeight: min((height ?? width) * 0.8, image.size.height / 2 * 1.5))
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            if attachment.kind == .video {
                Text("▶").font(.system(size: 22)).foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 3)
            }
        }
        .frame(width: width, height: height ?? width)
        .clipped()
        .contentShape(Rectangle())
        .task(id: attachment.id) { image = await Thumbnailer.image(for: attachment, maxPixels: 1100) }
    }
}

/// The writing, clipped to a few lines with "more", like a caption.
private struct Caption: View {
    let text: String
    @State private var expanded = false
    private var long: Bool { text.count > 260 || text.filter { $0 == "\n" }.count > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Theme.font(13))
                .lineSpacing(6)
                .foregroundStyle(Theme.ink)
                .lineLimit(expanded ? nil : 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(expanded ? "less" : "more") { withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() } }
                    .buttonStyle(TextButtonStyle())
                    .font(Theme.font(10))
            }
        }
    }
}

import SwiftUI

/// Replaces the calendar while searching: a prompt, a mode switch (meaning / words / date), then results.
struct SearchPanel: View {
    @ObservedObject private var search = SearchModel.shared
    @ObservedObject private var store = DiaryStore.shared
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var faces = FaceStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Text(">").foregroundStyle(Theme.red)
                TextField(placeholder, text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = search.hits.first { open(first) } }
                Button("[×]") { close() }
                    .buttonStyle(TextButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .font(Theme.font(13))

            HStack(spacing: 14) {
                ForEach(SearchModel.Mode.allCases, id: \.self) { m in
                    Button { withAnimation(.easeOut(duration: 0.2)) { search.mode = m }; focused = true } label: {
                        HStack(spacing: 6) { LED(on: search.mode == m, color: Theme.amber); Text(m.rawValue) }
                    }
                    .buttonStyle(TextButtonStyle(active: search.mode == m))
                }
                Spacer()
                if search.mode == .date, let dq = search.dateQuery {
                    Text("= " + dq.label).foregroundStyle(Theme.amber).transition(.opacity)
                }
            }
            .font(Theme.font(11))

            if search.mode == .meaning && !search.isAvailable {
                Text("the english sentence model isn't available on this mac.")
                    .foregroundStyle(Theme.faint)
            } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("try:").foregroundStyle(Theme.faint)
                    ForEach(examples, id: \.self) { s in
                        Button("  " + s) { search.query = s }.buttonStyle(TextButtonStyle())
                    }
                }
            } else if search.hits.isEmpty {
                if search.mode == .date, let dq = search.dateQuery {
                    // nothing written that day — offer to open it anyway
                    VStack(alignment: .leading, spacing: 8) {
                        Text("nothing written " + (dq.span == .day ? "on " : "in ") + dq.label + ".").foregroundStyle(Theme.faint)
                        if dq.span == .day, dq.start <= Date() {
                            Button("  [open " + dq.label + "]") {
                                withAnimation(.easeOut(duration: 0.28)) { nav.selected = dq.start; nav.month = dq.start }
                            }
                            .buttonStyle(TextButtonStyle())
                        }
                    }
                } else if search.mode == .date {
                    Text("couldn't read that as a date.").foregroundStyle(Theme.faint)
                } else {
                    Text("no matches.").foregroundStyle(Theme.faint)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(search.hits) { h in row(h) }
                    }
                }
            }

            Spacer(minLength: 0)

            if !search.hits.isEmpty {
                Text("\(search.hits.count) \(search.hits.count == 1 ? "result" : "results") · \(String(format: "%.1f", search.lastQueryMs)) ms · on-device")
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(Theme.font(11))
        .onAppear { focused = true }
    }

    private func row(_ h: SemanticIndex.Hit) -> some View {
        Button { open(h) } label: {
            HStack(alignment: .top, spacing: 10) {
                MoodFace(mood: store.entries[h.key]?.mood, size: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(h.key.replacingOccurrences(of: "-", with: "."))
                        Spacer()
                        switch search.mode {
                        case .meaning:
                            // match strength as a tiny bar
                            HStack(spacing: 1) {
                                ForEach(0..<5, id: \.self) { i in
                                    Rectangle()
                                        .fill(Float(i) < h.score * 5 ? Theme.sub : Theme.line)
                                        .frame(width: 3, height: 7)
                                }
                            }
                        case .words:
                            Text("×\(Int(h.score))").foregroundStyle(Theme.faint)
                        case .date:
                            if let d = DiaryStore.date(fromKey: h.key) {
                                Text(d.formatted(.dateTime.weekday(.abbreviated)).lowercased()).foregroundStyle(Theme.faint)
                            }
                        }
                    }
                    Text(highlighted(h.snippet))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .transition(.opacity)
    }

    private var placeholder: String {
        switch search.mode {
        case .meaning: return "search by meaning…"
        case .words:   return "search for words…"
        case .date:    return "a date: 11.04, nov 4, november…"
        }
    }

    private var examples: [String] {
        switch search.mode {
        case .meaning: return ["times i felt lonely", "stressed about school", "good food"]
        case .words:   return ["hackathon", "mom", "coffee"]
        case .date:    return ["yesterday", "last friday", "november", "2026.11.04"]
        }
    }

    /// In word search, the matched words stand out in the snippet.
    private func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard search.mode == .words else { return a }
        let lower = s.lowercased()
        for term in KeywordSearch.terms(search.query) {
            var from = lower.startIndex
            while let r = lower.range(of: term, range: from..<lower.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) {
                    a[lo..<hi].foregroundColor = Theme.ink
                    a[lo..<hi].backgroundColor = Theme.amber.opacity(0.25)
                }
                from = r.upperBound
            }
        }
        return a
    }

    private func open(_ h: SemanticIndex.Hit) {
        guard let d = DiaryStore.date(fromKey: h.key) else { return }
        withAnimation(.easeOut(duration: 0.28)) {
            nav.selected = d
            nav.month = d
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.28)) { nav.searching = false }
        search.query = ""
    }
}

import SwiftUI
import Charts

struct InsightsView: View {
    @ObservedObject private var store = DiaryStore.shared
    @ObservedObject private var faces = FaceStore.shared
    @ObservedObject private var nav = AppNav.shared
    @Environment(\.dismiss) private var dismiss

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var insights = Insights()

    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text("~/diary/insights")
                Spacer()
                Button("[‹]") { year -= 1 }.buttonStyle(TextButtonStyle())
                Text(String(year)).monospacedDigit().contentTransition(.numericText())
                Button("[›]") { year += 1 }.buttonStyle(TextButtonStyle())
                    .disabled(year >= cal.component(.year, from: Date()))
            }
            .font(Theme.font(12))

            yearGrid

            HStack(spacing: 0) {
                stat("days", insights.daysLogged)
                stat("streak", insights.currentStreak)
                stat("longest", insights.longestStreak)
                stat("words", insights.wordsWritten)
            }

            sentimentChart

            keywordTable

            HStack {
                Text("all analysis runs on this mac.").foregroundStyle(Theme.faint)
                Spacer()
                Button("[done]") { dismiss() }
                    .buttonStyle(TextButtonStyle(active: true))
                    .keyboardShortcut(.defaultAction)
            }
            .font(Theme.font(11))
        }
        .padding(30)
        .frame(width: 680)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .font(Theme.font(12))
        .onAppear { insights = Insights.compute(store.entries) }
        .animation(.easeOut(duration: 0.25), value: year)
    }

    // MARK: year in pixels

    private var yearGrid: some View {
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -lead, to: start)!
        let weeks = 53

        return HStack(alignment: .top, spacing: 2) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: gridStart)!
                        pixel(day, inYear: cal.component(.year, from: day) == year)
                    }
                }
            }
        }
        .id(year)
        .transition(.opacity)
    }

    @ViewBuilder private func pixel(_ day: Date, inYear: Bool) -> some View {
        let mood = store.entry(for: day)?.mood
        let future = day > Date()
        RoundedRectangle(cornerRadius: 1.5)
            .fill(mood.map { faces.style(for: $0).color.color } ?? Theme.line.opacity(future ? 0.25 : 0.6))
            .frame(width: 9, height: 9)
            .opacity(inYear ? 1 : 0)
            .help(inYear ? "\(DiaryStore.key(day))\(mood.map { "  " + faces.style(for: $0).label } ?? "")" : "")
            .onTapGesture {
                guard inYear, !future else { return }
                nav.selected = day
                nav.month = day
                dismiss()
            }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(Theme.font(20)).monospacedDigit()
            Text(label).font(Theme.font(10)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: picked mood vs. how the writing sounds

    private var sentimentChart: some View {
        let rows = insights.moods.filter { $0.averageSentiment != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Text("how your writing sounds, by mood")
                .font(Theme.font(11)).foregroundStyle(Theme.sub)
            if rows.isEmpty {
                Text("write a few entries to see this.")
                    .font(Theme.font(11)).foregroundStyle(Theme.faint)
                    .frame(height: 60, alignment: .topLeading)
            } else {
                Chart(rows) { r in
                    BarMark(x: .value("mood", name(r.mood)),
                            y: .value("tone", r.averageSentiment ?? 0),
                            width: .fixed(26))
                        .foregroundStyle(faces.style(for: r.mood).color.color)
                }
                .chartYScale(domain: -1...1)
                .chartYAxis {
                    AxisMarks(values: [-1, 0, 1]) { v in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel {
                            Text(v.as(Double.self).map { $0 > 0 ? "positive" : $0 < 0 ? "negative" : "neutral" } ?? "")
                                .font(Theme.font(9)).foregroundStyle(Theme.faint)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { v in
                        AxisValueLabel { Text(v.as(String.self) ?? "").font(Theme.font(10)).foregroundStyle(Theme.sub) }
                    }
                }
                .frame(height: 130)
            }
        }
    }

    // MARK: words per mood

    private var keywordTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("words you use most").font(Theme.font(11)).foregroundStyle(Theme.sub)
            ForEach(insights.moods) { s in
                HStack(spacing: 12) {
                    MoodFace(mood: s.mood, size: 16)
                    Text(name(s.mood)).frame(width: 90, alignment: .leading).lineLimit(1)
                    Text(s.keywords.isEmpty ? "—" : s.keywords.joined(separator: " · "))
                        .foregroundStyle(s.keywords.isEmpty ? Theme.faint : Theme.sub)
                        .lineLimit(1)
                    Spacer()
                    Text("\(s.days)d").monospacedDigit().foregroundStyle(Theme.faint)
                }
                .font(Theme.font(11))
            }
        }
    }

    private func name(_ m: Mood) -> String {
        let n = faces.style(for: m).label
        return n.isEmpty ? "untitled" : n
    }
}

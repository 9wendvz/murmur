import Foundation
import Testing
@testable import DiaryCore

// MARK: - Sentiment

@Suite struct SentimentTests {
    @Test func positiveWritingSuggestsAHappyFace() {
        let m = Sentiment.suggestedMood(for: "today was honestly amazing, i loved every minute of it")
        #expect(m == .rad || m == .good)
    }

    @Test func negativeWritingSuggestsASadFace() {
        let m = Sentiment.suggestedMood(for: "everything went wrong today and i feel awful and exhausted")
        #expect(m == .awful || m == .down)
    }

    @Test func tooLittleTextGivesNoSuggestion() {
        #expect(Sentiment.score("ok") == nil)
        #expect(Sentiment.score("   ") == nil)
    }

    @Test(arguments: [(1.0, Mood.rad), (0.3, .good), (0.0, .meh), (-0.3, .down), (-0.9, .awful)])
    func scoresMapOntoTheFiveFaces(score: Double, expected: Mood) {
        #expect(Sentiment.mood(for: score) == expected)
    }
}

// MARK: - Streaks

@Suite struct StreakTests {
    let cal = Calendar(identifier: .gregorian)
    func day(_ s: String) -> Date { DiaryStore.date(fromKey: s)! }

    @Test func countsCurrentAndLongestRuns() {
        let keys: Set = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04",   // 4 in a row
                         "2026-11-10", "2026-11-11", "2026-11-12"]                   // 3, ending today
        let (current, longest) = Insights.streaks(keys, today: day("2026-11-12"), calendar: cal)
        #expect(current == 3)
        #expect(longest == 4)
    }

    @Test func currentStreakSurvivesUntilTodayIsLogged() {
        let keys: Set = ["2026-11-10", "2026-11-11"]
        #expect(Insights.streaks(keys, today: day("2026-11-12"), calendar: cal).0 == 2)
    }

    @Test func gapBreaksTheStreak() {
        let keys: Set = ["2026-11-09", "2026-11-10"]
        #expect(Insights.streaks(keys, today: day("2026-11-12"), calendar: cal).0 == 0)
    }

    @Test func monthBoundaryIsStillConsecutive() {
        let keys: Set = ["2026-10-31", "2026-11-01"]
        #expect(Insights.streaks(keys, today: day("2026-11-01"), calendar: cal) == (2, 2))
    }
}

// MARK: - Keywords

@Suite struct KeywordTests {
    @Test func picksMeaningfulRepeatedWordsAndSkipsFiller() {
        let words = Insights.keywords(in: [
            "went to the beach with friends, the beach was sunny",
            "really just a beach day with my friends",
        ], limit: 3)
        #expect(words.first == "beach")
        #expect(words.contains("friend"))      // lemmatised
        #expect(!words.contains("really"))
        #expect(!words.contains("the"))
    }

    @Test func punctuationDoesNotSplitAWordInTwo() {
        let words = Insights.keywords(in: ["i feel tired. i feel calm, i feel."], limit: 5)
        #expect(words.filter { $0.hasPrefix("feel") } == ["feel"])
        #expect(words.allSatisfy { $0.allSatisfy(\.isLetter) })
    }
}

// MARK: - Saved data

@Suite struct EntryCodingTests {
    func decode(_ json: String) throws -> Entry {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Entry.self, from: Data(json.utf8))
    }

    @Test func readsEntriesFromTheFirstVersionOfTheApp() throws {
        // v1 had activity tags and no attachments
        let e = try decode(#"{"mood":5,"text":"hi","tags":["work"],"updated":"2026-11-01T10:00:00Z"}"#)
        #expect(e.mood == .rad)
        #expect(e.text == "hi")
        #expect(e.attachments.isEmpty)
    }

    @Test func roundTripsAttachments() throws {
        var e = Entry()
        e.mood = .meh
        e.attachments = [Attachment(kind: .audio, file: "a.m4a")]
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let back = try decode(String(decoding: try enc.encode(e), as: UTF8.self))
        #expect(back.attachments.map(\.id) == e.attachments.map(\.id))
        #expect(back.attachments.map(\.file) == e.attachments.map(\.file))
        // timestamps are stored to the second
        #expect(abs(back.attachments[0].added!.timeIntervalSince(e.attachments[0].added!)) < 1)
        #expect(back.mood == .meh)
    }

    @Test func emptyEntryIsDropped() {
        #expect(Entry().isEmpty)
        var e = Entry()
        e.text = "  \n "
        #expect(e.isEmpty)
    }

    @Test func facesFromOlderVersionsKeepColourAndDrawing() throws {
        let json = #"{"label":"happy","color":{"r":1,"g":0.8,"b":0.3},"eyes":"ovals","mouth":"grin","extras":["cheeks"],"drawing":[{"points":[[0.5,0.5]],"color":{"r":0,"g":0,"b":0},"width":0.05,"erase":false}]}"#
        let f = try JSONDecoder().decode(FaceStyle.self, from: Data(json.utf8))
        #expect(f.label == "happy")
        #expect(f.drawing.count == 1)
    }
}

// MARK: - Semantic search

@Suite struct SearchTests {
    @Test func splitsLowercaseSentences() {
        let c = SemanticIndex.chunks(of: "went to class and took notes. had ramen with mom after. ok")
        #expect(c.count == 3)                        // whole entry + 2 sentences ("ok" is too short)
        #expect(c[1] == "went to class and took notes.")
    }

    @Test func findsEntriesByMeaningNotJustWords() {
        let index = SemanticIndex()
        guard index.isAvailable else { return }
        index.sync(with: [
            "2026-01-01": "i spent the whole evening alone in my room and nobody texted me back",
            "2026-01-02": "baked cookies and burned half of them",
            "2026-01-03": "ran 5k this morning and my legs are dead",
        ])
        let hits = index.search("cooking", limit: 3, minScore: -1)
        #expect(hits.first?.key == "2026-01-02")
    }

    @Test func reindexesOnlyWhatChanged() {
        let index = SemanticIndex()
        guard index.isAvailable else { return }
        #expect(index.sync(with: ["a": "first entry about the beach", "b": "second entry about school"]))
        #expect(!index.sync(with: ["a": "first entry about the beach", "b": "second entry about school"]))
        #expect(index.sync(with: ["a": "first entry about the beach"]))          // b deleted
        #expect(Set(index.chunkKeys) == ["a"])
    }

    @Test func blasAndPlainLoopAgree() {
        let index = SemanticIndex()
        guard index.isAvailable else { return }
        index.sync(with: ["a": "sunny walk in the park", "b": "rainy day inside", "c": "exam stress"])
        let q = index.vector("weather")!
        for (x, y) in zip(index.similarities(q), index.similaritiesNaive(q)) { #expect(abs(x - y) < 1e-4) }
    }

    @Test func savedIndexLoadsBackIdentically() throws {
        let index = SemanticIndex()
        guard index.isAvailable else { return }
        index.sync(with: ["a": "went hiking with friends. it was beautiful up there.", "b": "quiet day at home"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.save(to: dir)

        let loaded = SemanticIndex()
        #expect(loaded.load(from: dir))
        #expect(loaded.chunkKeys == index.chunkKeys)
        #expect(loaded.matrix == index.matrix)
        #expect(!loaded.sync(with: ["a": "went hiking with friends. it was beautiful up there.", "b": "quiet day at home"]))
    }
}

// MARK: - Custom emotions

@Suite struct MoodTests {
    @Test func customMoodsSaveAsPlainNumbers() throws {
        let m = Mood(rawValue: 7)!
        #expect(String(decoding: try JSONEncoder().encode(m), as: UTF8.self) == "7")
        #expect(try JSONDecoder().decode(Mood.self, from: Data("7".utf8)) == m)
        #expect(!m.isBuiltIn && Mood.rad.isBuiltIn)
    }

    @Test func rejectsInvalidMoods() {
        #expect(Mood(rawValue: 0) == nil)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Mood.self, from: Data("-1".utf8)) }
    }
}

// MARK: - Timestamps

@Suite struct TimestampTests {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func olderEntriesWithoutCreatedStillLoad() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let e = try d.decode(Entry.self, from: Data(#"{"text":"hi","updated":"2026-11-01T10:00:00Z"}"#.utf8))
        #expect(e.created == nil)
        let a = try d.decode(Attachment.self, from: Data(#"{"id":"8A7F4A56-B090-4246-875A-6FC9A73B3950","kind":"audio","file":"x.m4a"}"#.utf8))
        #expect(a.added == nil)
    }

    @Test func showsEditedOnlyWhenLaterThanWritten() {
        var e = Entry()
        e.created = at("2026-11-12T10:00:00Z")
        e.updated = at("2026-11-12T10:00:30Z")
        let day = e.created!
        #expect(!EntryEditor.timestamps(e, day: day).contains("edited"))
        e.updated = at("2026-11-12T12:30:00Z")
        #expect(EntryEditor.timestamps(e, day: day).contains("edited"))
    }

    @Test func editsOnAnotherDayShowTheDate() {
        var e = Entry()
        e.created = at("2026-11-12T10:00:00Z")
        e.updated = at("2026-11-14T10:00:00Z")
        #expect(EntryEditor.timestamps(e, day: e.created!).contains("11.14"))
    }
}

// MARK: - Important dates

@Suite struct ImportantDateTests {
    let cal = Calendar(identifier: .gregorian)
    func day(_ s: String) -> Date { DiaryStore.date(fromKey: s)! }

    @Test func yearlyDateRollsToNextYearOnceItHasPassed() {
        let bday = ImportantDate(title: "mom", day: "1970-03-14", yearly: true)
        #expect(bday.nextOccurrence(from: day("2026-01-10"), calendar: cal) == day("2026-03-14"))
        #expect(bday.nextOccurrence(from: day("2026-11-12"), calendar: cal) == day("2027-03-14"))
        #expect(bday.nextOccurrence(from: day("2026-03-14"), calendar: cal) == day("2026-03-14"))   // today counts
    }

    @Test func oneOffDateDisappearsAfterwards() {
        let exam = ImportantDate(title: "exam", day: "2026-12-03", yearly: false)
        #expect(exam.nextOccurrence(from: day("2026-11-12"), calendar: cal) == day("2026-12-03"))
        #expect(exam.nextOccurrence(from: day("2026-12-04"), calendar: cal) == nil)
    }

    @Test func leapDayFallsBackToFeb28() {
        let leap = ImportantDate(title: "leap", day: "2024-02-29", yearly: true)
        #expect(leap.nextOccurrence(from: day("2026-01-01"), calendar: cal) == day("2026-02-28"))
        #expect(leap.nextOccurrence(from: day("2028-01-01"), calendar: cal) == day("2028-02-29"))
    }

    @Test func reminderFiresDaysBeforeAt9() {
        let d = ImportantDate(title: "anniv", day: "2020-11-20", yearly: true, remindDaysBefore: 3)
        let fire = d.reminderDate(from: day("2026-11-12"), calendar: cal)!
        #expect(cal.dateComponents([.month, .day, .hour], from: fire) == DateComponents(month: 11, day: 17, hour: 9))
    }

    @Test func reminderInThePastIsSkipped() {
        let d = ImportantDate(title: "x", day: "2026-11-13", yearly: false, remindDaysBefore: 7)   // would be 11-06
        #expect(d.reminderDate(from: day("2026-11-12"), calendar: cal) == nil)
    }

    @Test func fallsOnMatchesTheRightDayOnly() {
        let d = ImportantDate(title: "x", day: "1999-07-04", yearly: true)
        #expect(d.falls(on: day("2026-07-04"), calendar: cal))
        #expect(!d.falls(on: day("2026-07-05"), calendar: cal))
    }
}

// MARK: - To-do

@Suite struct TodoTests {
    let cal = Calendar.current
    let now = DiaryStore.date(fromKey: "2026-11-12")!.addingTimeInterval(10 * 3600)   // Thu 10:00

    @Test func readsDueDatesFromPlainWords() {
        let t = TodoItem.parse("call mom tomorrow", now: now)
        #expect(t.title == "call mom")
        #expect(t.due.map { cal.isDate($0, inSameDayAs: cal.date(byAdding: .day, value: 1, to: Date())!) } == true)
    }

    @Test func keepsTheTaskWhenThereIsNoDate() {
        let t = TodoItem.parse("  buy oat milk  ")
        #expect(t.title == "buy oat milk")
        #expect(t.due == nil)
    }

    @Test func dueFridayMeansFridayNotToday() {
        // the date detector alone reads "due friday" as today; make sure it lands on a Friday
        let t = TodoItem.parse("essay due friday")
        #expect(t.title == "essay")
        #expect(t.due.map { Calendar.current.component(.weekday, from: $0) } == 6)
    }

    @Test func dropsLeftoverLinkWords() {
        #expect(TodoItem.parse("read ch 4 by monday").title == "read ch 4")
        #expect(TodoItem.parse("dentist on nov 20 at 3pm").title == "dentist")
    }

    @Test func overdueFirstThenSoonestThenUndatedThenDone() {
        let today = DiaryStore.date(fromKey: "2026-11-12")!
        let late = TodoItem(title: "late", due: "2026-11-10")
        let soon = TodoItem(title: "soon", due: "2026-11-13")
        let later = TodoItem(title: "later", due: "2026-11-30")
        let whenever = TodoItem(title: "whenever")
        var finished = TodoItem(title: "finished", due: "2026-11-01"); finished.done = Date()
        let order = TodoItem.sorted([whenever, finished, later, soon, late], today: today).map(\.title)
        #expect(order == ["late", "soon", "later", "whenever", "finished"])
    }

    @Test func daysLeftIsNegativeWhenLate() {
        let today = DiaryStore.date(fromKey: "2026-11-12")!
        #expect(TodoItem(title: "x", due: "2026-11-10").daysLeft(from: today) == -2)
        #expect(TodoItem(title: "x", due: "2026-11-12").daysLeft(from: today) == 0)
    }
}

// MARK: - Copying attachments

import AppKit

@Suite struct ClipboardTests {
    /// A tiny real JPEG on disk.
    func photo() throws -> URL {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString).jpg")
        try rep.representation(using: .jpeg, properties: [:])!.write(to: url)
        return url
    }

    @Test @MainActor func copiedPhotoPastesBackAsAFileEvenAfterTheOriginalIsGone() throws {
        let pb = NSPasteboard(name: .init("diary-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let original = try photo()
        let copied = try #require(MediaClipboard.copy(file: original, kind: .photo, to: pb))
        #expect(copied != original)

        try FileManager.default.removeItem(at: original)            // "cut" deletes the original
        #expect(FileManager.default.fileExists(atPath: copied.path))

        #expect(NotebookTextView.hasMedia(pb))
        var received: [URL] = []
        let tv = NotebookTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.onImport = { media, _ in if case .files(let urls) = media { received = urls } }
        #expect(tv.importMedia(from: pb, at: .zero))
        #expect(received == [copied])
        // other apps get the picture too
        #expect(NSImage(pasteboard: pb) != nil)
    }
}

// MARK: - Clock

@Suite struct ClockTests {
    func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: h, minute: m, second: s))!
    }

    @Test func twelveHourLowercase() {
        #expect(Clock.time(at(2, 40)) == "2:40 am")
        #expect(Clock.time(at(14, 5)) == "2:05 pm")
        #expect(Clock.time(at(0, 0)) == "12:00 am")
        #expect(Clock.time(at(12, 30)) == "12:30 pm")
        #expect(Clock.timeWithSeconds(at(23, 5, 9)) == "11:05:09 pm")
    }
}

// MARK: - Date & keyword search

@Suite struct DateQueryTests {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!   // Thu
    func q(_ s: String) -> String? { DateQuery.parse(s, now: now).map(\.label) }

    @Test func numericDates() {
        #expect(q("2026.11.04") == "2026.11.04")
        #expect(q("2026-11-04") == "2026.11.04")
        #expect(q("11.04") == "2026.11.04")
        #expect(q("11/04/26") == "2026.11.04")
    }

    @Test func dateWithoutYearThatHasntHappenedYetMeansLastYear() {
        #expect(q("12.25") == "2025.12.25")
    }

    @Test func monthsAndYears() {
        #expect(q("2026.11") == "2026.11")
        #expect(q("november") == "2026.11")
        #expect(q("nov") == "2026.11")
        #expect(q("december") == "2025.12")       // this year's december hasn't happened yet
        #expect(q("march 2025") == "2025.03")
        #expect(q("2025") == "2025")
        #expect(DateQuery.parse("november", now: now)?.span == .month)
    }

    @Test func wordsLikeYesterdayAndLastFriday() {
        #expect(q("yesterday") == "2026.11.11")
        #expect(q("nov 4") == "2026.11.04")
        // "friday" alone means the one just gone, not tomorrow
        #expect(q("friday") == "2026.11.06")
    }

    @Test func nonsenseIsNotADate() {
        #expect(q("hackathon") == nil)
        #expect(q("13.45") == nil)
    }

    @Test func monthQueryMatchesEveryDayInIt() {
        let dq = DateQuery.parse("2026.11", now: now)!
        #expect(dq.contains(key: "2026-11-01") && dq.contains(key: "2026-11-30"))
        #expect(!dq.contains(key: "2026-10-31"))
    }
}

@Suite struct KeywordSearchTests {
    let entries = [
        "2026-11-02": "SO HAPPILY tired. went to the farmers market",
        "2026-11-04": "i am so happy today, the sun finally came out",
        "2026-11-10": "coffee with mom, then more coffee",
    ]

    @Test func findsEntriesWithEveryWord() {
        #expect(KeywordSearch.search(entries, "happy").map(\.key) == ["2026-11-04"])
        #expect(KeywordSearch.search(entries, "so happ").map(\.key) == ["2026-11-04", "2026-11-02"])   // newest first
        #expect(KeywordSearch.search(entries, "coffee mom").map(\.key) == ["2026-11-10"])
        #expect(KeywordSearch.search(entries, "coffee beach").isEmpty)
    }

    @Test func ignoresCaseAndCountsHits() {
        let hit = KeywordSearch.search(entries, "COFFEE").first!
        #expect(hit.score == 2)
    }

    @Test func snippetCentresOnTheMatch() {
        let long = String(repeating: "blah ", count: 40) + "the beach was lovely" + String(repeating: " blah", count: 40)
        let s = KeywordSearch.snippet(long, around: "beach")
        #expect(s.contains("beach") && s.hasPrefix("…") && s.hasSuffix("…") && s.count < 120)
    }
}

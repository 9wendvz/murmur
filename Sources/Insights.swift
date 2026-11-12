import Foundation
import NaturalLanguage

// MARK: - On-device sentiment

/// Reads the emotional tone of an entry with Apple's on-device NaturalLanguage model.
/// Nothing leaves the Mac.
enum Sentiment {
    private static let cache = NSCache<NSString, NSNumber>()

    /// Average sentence sentiment in -1 (negative) … 1 (positive), or nil if there's too little text to judge.
    static func score(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= 4 else { return nil }
        if let hit = cache.object(forKey: trimmed as NSString) { return hit.doubleValue }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = trimmed
        var total = 0.0, weight = 0.0
        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .sentence,
                             scheme: .sentimentScore, options: [.omitWhitespace]) { tag, range in
            if let tag, let v = Double(tag.rawValue) {
                // longer sentences count for more
                let w = Double(trimmed[range].count)
                total += v * w
                weight += w
            }
            return true
        }
        guard weight > 0 else { return nil }
        let result = total / weight
        cache.setObject(NSNumber(value: result), forKey: trimmed as NSString)
        return result
    }

    /// Maps a sentiment score onto the five-face scale.
    static func mood(for score: Double) -> Mood {
        switch score {
        case 0.5...:       return .rad
        case 0.15..<0.5:   return .good
        case -0.15..<0.15: return .meh
        case -0.5 ..< -0.15: return .down
        default:           return .awful
        }
    }

    static func suggestedMood(for text: String) -> Mood? { score(text).map(mood(for:)) }
}

// MARK: - Insights engine

struct MoodStats: Identifiable {
    let mood: Mood
    var days: Int
    /// Average sentiment of the writing on days with this mood (nil if none had enough text).
    var averageSentiment: Double?
    var keywords: [String]
    var id: Int { mood.rawValue }
}

struct Insights {
    var daysLogged = 0
    var wordsWritten = 0
    var currentStreak = 0
    var longestStreak = 0
    var moods: [MoodStats] = []

    /// Pure function of the entries, so it's easy to test.
    static func compute(_ entries: [String: Entry], today: Date = Date(), calendar: Calendar = .current) -> Insights {
        var out = Insights()
        let logged = entries.filter { $0.value.mood != nil }
        out.daysLogged = logged.count
        out.wordsWritten = entries.values.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        (out.currentStreak, out.longestStreak) = streaks(Set(logged.keys), today: today, calendar: calendar)

        out.moods = Mood.picker.map { mood in
            let days = logged.values.filter { $0.mood == mood }
            let scores = days.compactMap { Sentiment.score($0.text) }
            return MoodStats(
                mood: mood,
                days: days.count,
                averageSentiment: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                keywords: keywords(in: days.map(\.text), limit: 5))
        }
        return out
    }

    /// (current, longest) runs of consecutive logged days. The current streak may end today or yesterday.
    static func streaks(_ keys: Set<String>, today: Date, calendar: Calendar) -> (Int, Int) {
        let days = keys.compactMap { DiaryStore.date(fromKey: $0) }.map { calendar.startOfDay(for: $0) }.sorted()
        var longest = 0, run = 0
        var prev: Date?
        for d in days {
            if let p = prev, calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            prev = d
        }

        var current = 0
        var day = calendar.startOfDay(for: today)
        if !keys.contains(DiaryStore.key(day)) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while keys.contains(DiaryStore.key(day)) {
            current += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return (current, longest)
    }

    private static let stopwords: Set<String> = [
        "be", "have", "do", "get", "go", "make", "know", "think", "take", "see", "come", "want", "say",
        "thing", "stuff", "lot", "way", "day", "today", "really", "just", "also", "very", "much", "more",
        "still", "even", "lol", "kind", "bit", "time", "honestly", "would", "could", "should", "will",
        "able", "dont", "im", "ive", "thats",
    ]

    /// Most frequent meaningful words (nouns, verbs, adjectives, as base forms) across some texts.
    static func keywords(in texts: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        let keep: Set<NLTag> = [.noun, .verb, .adjective]
        for text in texts where !text.isEmpty {
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
                guard let tag, keep.contains(tag) else { return true }
                let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                // the lemma can carry stray punctuation ("feel."), so keep letters only
                let word = (lemma ?? String(text[range])).lowercased().filter(\.isLetter)
                if word.count >= 3, !stopwords.contains(word) { counts[word, default: 0] += 1 }
                return true
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }
}

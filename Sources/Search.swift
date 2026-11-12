import Foundation
import NaturalLanguage
import Accelerate
import CryptoKit

/// Search by meaning, on-device.
///
/// Each entry is split into chunks (the whole entry plus each sentence). Every chunk is embedded with
/// Apple's on-device sentence-embedding model into a 512-d vector, L2-normalised, and stored row-wise in one
/// contiguous matrix. A query is embedded the same way, and a single matrix-vector multiply (Accelerate/BLAS)
/// gives the cosine similarity against every chunk at once. An entry scores as its best chunk, plus a small
/// boost when it also contains a query word verbatim (hybrid semantic + lexical ranking).
final class SemanticIndex {
    struct Hit: Identifiable, Equatable {
        let key: String          // "yyyy-MM-dd"
        let score: Float         // 0…1-ish
        let snippet: String      // best-matching sentence
        var id: String { key }
    }

    private let embedding: NLEmbedding?
    let dimension: Int
    /// Worker count for parallel embedding (1 = serial, for benchmarking).
    var parallelism = max(1, ProcessInfo.processInfo.activeProcessorCount)

    // Row-major [chunkCount × dimension] matrix of unit vectors.
    private(set) var matrix: [Float] = []
    private(set) var chunkKeys: [String] = []
    private var chunkText: [String] = []
    private var indexedHash: [String: String] = [:]   // key → hash of the text that was indexed
    private var entryText: [String: String] = [:]

    var chunkCount: Int { chunkKeys.count }
    var isAvailable: Bool { embedding != nil }

    init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        dimension = embedding?.dimension ?? 0
    }

    // MARK: indexing

    /// Brings the index in line with `entries`, re-embedding only entries whose text changed.
    /// Returns true if anything changed.
    @discardableResult
    func sync(with entries: [String: String]) -> Bool {
        guard isAvailable else { return false }
        entryText = entries
        let changed = entries.filter { indexedHash[$0.key] != Self.hash($0.value) }.map(\.key).sorted()
        let removed = indexedHash.keys.filter { entries[$0] == nil }
        guard !changed.isEmpty || !removed.isEmpty else { return false }

        let drop = Set(changed).union(removed)
        removeChunks(for: drop)
        for k in removed { indexedHash[k] = nil }

        // Flatten to (key, chunk) jobs, then embed them in parallel. Each worker gets its own model
        // instance, and writes only into its own slots of the output, so no locking is needed.
        let jobs: [(key: String, text: String)] = changed.flatMap { k in Self.chunks(of: entries[k]!).map { (k, $0) } }
        var vectors = [[Float]?](repeating: nil, count: jobs.count)
        let workers = min(parallelism, max(1, jobs.count))
        vectors.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                let model = w == 0 ? embedding : NLEmbedding.sentenceEmbedding(for: .english)
                var i = w
                while i < jobs.count {
                    out[i] = Self.unitVector(jobs[i].text, model)
                    i += workers
                }
            }
        }
        for (i, job) in jobs.enumerated() {
            guard let v = vectors[i] else { continue }
            matrix.append(contentsOf: v)
            chunkKeys.append(job.key)
            chunkText.append(job.text)
        }
        for k in changed { indexedHash[k] = Self.hash(entries[k]!) }
        return true
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func removeChunks(for keys: Set<String>) {
        var m: [Float] = [], ks: [String] = [], ts: [String] = []
        m.reserveCapacity(matrix.count)
        for i in chunkKeys.indices where !keys.contains(chunkKeys[i]) {
            m.append(contentsOf: matrix[i * dimension ..< (i + 1) * dimension])
            ks.append(chunkKeys[i]); ts.append(chunkText[i])
        }
        matrix = m; chunkKeys = ks; chunkText = ts
    }

    /// The whole entry, plus each sentence of 3+ words when there's more than one.
    /// (Splits on . ! ? and newlines itself: Apple's sentence tokenizer won't split all-lowercase text.)
    static func chunks(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for ch in trimmed {
            if ch == "\n" || ".!?".contains(ch) {
                if ch != "\n" { current.append(ch) }
                let s = current.trimmingCharacters(in: .whitespaces)
                if s.split(whereSeparator: \.isWhitespace).count >= 3 { sentences.append(s) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if tail.split(whereSeparator: \.isWhitespace).count >= 3 { sentences.append(tail) }
        return sentences.count > 1 ? [trimmed] + sentences : [trimmed]
    }

    /// Unit-length embedding of a piece of text.
    func vector(_ text: String) -> [Float]? { Self.unitVector(text, embedding) }

    static func unitVector(_ text: String, _ embedding: NLEmbedding?) -> [Float]? {
        guard let v = embedding?.vector(for: text.lowercased()) else { return nil }
        var f = v.map(Float.init)
        var norm: Float = 0
        vDSP_svesq(f, 1, &norm, vDSP_Length(f.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        vDSP_vsdiv(f, 1, &norm, &f, 1, vDSP_Length(f.count))
        return f
    }

    // MARK: saving to disk

    private struct Header: Codable {
        var version = 2
        var dimension: Int
        var chunkKeys: [String]
        var chunkText: [String]
        var indexedHash: [String: String]
    }

    /// Writes the index as a small JSON header plus a raw Float32 matrix.
    func save(to dir: URL) throws {
        let header = Header(dimension: dimension, chunkKeys: chunkKeys, chunkText: chunkText, indexedHash: indexedHash)
        try JSONEncoder().encode(header).write(to: dir.appendingPathComponent("search-index.json"), options: .atomic)
        try matrix.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: dir.appendingPathComponent("search-index.f32"), options: .atomic)
    }

    /// Loads a saved index. Returns false (leaving the index empty) if it's missing or doesn't match the model.
    @discardableResult
    func load(from dir: URL) -> Bool {
        guard isAvailable,
              let h = try? JSONDecoder().decode(Header.self, from: Data(contentsOf: dir.appendingPathComponent("search-index.json"))),
              h.version == 2, h.dimension == dimension,
              let raw = try? Data(contentsOf: dir.appendingPathComponent("search-index.f32")),
              raw.count == h.chunkKeys.count * dimension * MemoryLayout<Float>.size else { return false }
        matrix = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        chunkKeys = h.chunkKeys
        chunkText = h.chunkText
        indexedHash = h.indexedHash
        return true
    }

    // MARK: querying

    /// Cosine similarity of `q` against every chunk, via one BLAS matrix-vector multiply.
    func similarities(_ q: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: chunkCount)
        guard chunkCount > 0 else { return out }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(chunkCount), Int32(dimension),
                    1, matrix, Int32(dimension), q, 1, 0, &out, 1)
        return out
    }

    /// The same thing with plain Swift loops, kept for the benchmark comparison.
    func similaritiesNaive(_ q: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: chunkCount)
        for i in 0..<chunkCount {
            var dot: Float = 0
            let base = i * dimension
            for j in 0..<dimension { dot += matrix[base + j] * q[j] }
            out[i] = dot
        }
        return out
    }

    func search(_ query: String, limit: Int = 30, minScore: Float = 0.25) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let qv = vector(q) else { return [] }
        let sims = similarities(qv)
        let words = Self.contentWords(q)

        var best: [String: (Float, String)] = [:]
        for i in 0..<chunkCount where sims[i] > (best[chunkKeys[i]]?.0 ?? -1) {
            best[chunkKeys[i]] = (sims[i], chunkText[i])
        }
        let hits: [Hit] = best.compactMap { key, b in
            var score = b.0
            let text = (entryText[key] ?? "").lowercased()
            if !words.isEmpty, words.contains(where: { text.contains($0) }) { score += 0.15 }   // lexical boost
            guard score > minScore else { return nil }
            return Hit(key: key, score: min(score, 1), snippet: b.1)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func contentWords(_ s: String) -> [String] {
        let skip: Set<String> = ["the", "and", "times", "when", "about", "with", "that", "felt", "feel", "was", "were", "what", "did"]
        return s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !skip.contains($0) }
    }
}

// MARK: - App-facing search model

/// Keeps the index in sync with the diary on a background queue and publishes results to the UI.
final class SearchModel: ObservableObject {
    static let shared = SearchModel()

    enum Mode: String, CaseIterable { case meaning, words, date }

    @Published var query = "" { didSet { schedule() } }
    @Published var mode: Mode = .meaning { didSet { hits = []; schedule() } }
    @Published private(set) var hits: [SemanticIndex.Hit] = []
    /// What a date search understood ("2026.11", "2026.11.04"…), shown so you can see how it was read.
    @Published private(set) var dateQuery: DateQuery?
    @Published private(set) var lastQueryMs: Double = 0

    private let index = SemanticIndex()
    private let queue = DispatchQueue(label: "diary.search", qos: .userInitiated)
    private var pending: DispatchWorkItem?

    var isAvailable: Bool { index.isAvailable }

    init() {
        // Load the saved index and catch up with any edits, in the background at launch.
        queue.async { [index] in
            index.load(from: DiaryStore.directory)
            let texts = DispatchQueue.main.sync { DiaryStore.shared.entries.compactMapValues { $0.text.isEmpty ? nil : $0.text } }
            if index.sync(with: texts) { try? index.save(to: DiaryStore.directory) }
        }
    }

    private func schedule() {
        pending?.cancel()
        let q = query
        let mode = self.mode
        let entries = DiaryStore.shared.entries
        let texts = entries.compactMapValues { $0.text.isEmpty ? nil : $0.text }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.index.sync(with: texts) { try? self.index.save(to: DiaryStore.directory) }
            let t0 = DispatchTime.now()
            var parsed: DateQuery?
            let hits: [SemanticIndex.Hit]
            switch mode {
            case .meaning:
                hits = self.index.search(q)
            case .words:
                hits = KeywordSearch.search(texts, q)
            case .date:
                parsed = DateQuery.parse(q)
                hits = parsed.map { dq in
                    entries.filter { dq.contains(key: $0.key) }.map { k, e in
                        let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                        return SemanticIndex.Hit(key: k, score: 1, snippet: t.isEmpty ? "—" : String(t.prefix(100)))
                    }
                    .sorted { $0.key > $1.key }
                } ?? []
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            DispatchQueue.main.async {
                guard self.query == q, self.mode == mode else { return }
                self.hits = hits
                self.dateQuery = parsed
                self.lastQueryMs = ms
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: - Keyword search

enum KeywordSearch {
    /// Entries containing every word of the query (case-insensitive), newest first, with a snippet around the first hit.
    static func search(_ entries: [String: String], _ query: String, limit: Int = 50) -> [SemanticIndex.Hit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        return entries.compactMap { key, text -> SemanticIndex.Hit? in
            let lower = text.lowercased()
            guard terms.allSatisfy({ lower.contains($0) }) else { return nil }
            let count = terms.reduce(0) { n, t in n + lower.components(separatedBy: t).count - 1 }
            return SemanticIndex.Hit(key: key, score: Float(count), snippet: snippet(text, around: terms[0]))
        }
        .sorted { $0.key > $1.key }
        .prefix(limit).map { $0 }
    }

    static func terms(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    /// ~100 characters around the first match, with "…" where it was cut.
    static func snippet(_ text: String, around term: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: term, options: .caseInsensitive) else { return String(flat.prefix(100)) }
        let start = flat.index(r.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < flat.endIndex ? "…" : "")
    }
}

// MARK: - Date search

/// A day, month or year typed in plain words: "11.04", "2026-11-04", "nov 4", "november", "2026.11", "2025",
/// "yesterday", "last friday".
struct DateQuery: Equatable {
    enum Span { case day, month, year }
    let start: Date
    let span: Span

    func contains(key: String, calendar cal: Calendar = .current) -> Bool {
        guard let d = DiaryStore.date(fromKey: key) else { return false }
        switch span {
        case .day:   return cal.isDate(d, inSameDayAs: start)
        case .month: return cal.isDate(d, equalTo: start, toGranularity: .month)
        case .year:  return cal.isDate(d, equalTo: start, toGranularity: .year)
        }
    }

    var label: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: start)
        switch span {
        case .day:   return String(format: "%04d.%02d.%02d", c.year!, c.month!, c.day!)
        case .month: return String(format: "%04d.%02d", c.year!, c.month!)
        case .year:  return String(c.year!)
        }
    }

    static func parse(_ raw: String, now: Date = Date(), calendar cal: Calendar = .current) -> DateQuery? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let thisYear = cal.component(.year, from: now)
        func day(_ y: Int, _ m: Int, _ d: Int) -> DateQuery? {
            guard (1...12).contains(m), (1...31).contains(d),
                  let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
                  cal.component(.month, from: date) == m else { return nil }
            return DateQuery(start: date, span: .day)
        }
        func month(_ y: Int, _ m: Int) -> DateQuery? {
            guard (1...12).contains(m), let date = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return nil }
            return DateQuery(start: date, span: .month)
        }
        /// "11.04" with no year: this year, unless that's still ahead — then last year (a diary looks back).
        func pastYear(_ m: Int, _ d: Int) -> Int {
            guard let date = cal.date(from: DateComponents(year: thisYear, month: m, day: d)) else { return thisYear }
            return date > now ? thisYear - 1 : thisYear
        }
        let nums = q.split(whereSeparator: { ".-/ ".contains($0) }).compactMap { Int($0) }
        let allNumeric = q.allSatisfy { $0.isNumber || ".-/".contains($0) }

        if allNumeric {
            switch nums.count {
            case 3 where nums[0] > 31: return day(nums[0], nums[1], nums[2])           // 2026.11.04
            case 3:                    return day(nums[2] < 100 ? 2000 + nums[2] : nums[2], nums[0], nums[1])   // 11/04/26
            case 2 where nums[0] > 31: return month(nums[0], nums[1])                  // 2026.11
            case 2:                    return day(pastYear(nums[0], nums[1]), nums[0], nums[1])                 // 11.04
            case 1 where nums[0] > 1900 && nums[0] < 3000:
                return cal.date(from: DateComponents(year: nums[0], month: 1, day: 1)).map { DateQuery(start: $0, span: .year) }
            default: return nil
            }
        }

        // a month name, alone or with a year: "nov", "november 2025"
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let names = f.monthSymbols.map { $0.lowercased() } + f.shortMonthSymbols.map { $0.lowercased() }
        let words = q.split(separator: " ").map(String.init)
        if let i = names.firstIndex(where: { words.first == $0 || words.first == $0 + "." }) {
            let m = i % 12 + 1
            if words.count == 1 { return month(cal.date(from: DateComponents(year: thisYear, month: m))! > now ? thisYear - 1 : thisYear, m) }
            if words.count == 2, let y = Int(words[1]), y > 1900 { return month(y, m) }
        }

        // everything else ("nov 4", "4th of november", "yesterday", "last friday") → Apple's date detector
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = det.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), var d = match.date else { return nil }
        if d > now {
            // the detector reads "friday" as the *next* one; a diary means the last one
            let ahead = cal.dateComponents([.day], from: now, to: d).day ?? 0
            d = cal.date(byAdding: ahead < 7 ? .day : .year, value: ahead < 7 ? -7 : -1, to: d) ?? d
        }
        return DateQuery(start: cal.startOfDay(for: d), span: .day)
    }
}

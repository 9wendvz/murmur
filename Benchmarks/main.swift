// Performance + retrieval-quality benchmarks. Run with ./bench.sh
import Foundation
@testable import DiaryCore

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - helpers

struct RNG: RandomNumberGenerator {          // deterministic, so runs are comparable
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

func ms(_ body: () -> Void) -> Double {
    let t0 = DispatchTime.now(); body()
    return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
}

func stats(_ runs: Int, _ body: () -> Void) -> (p50: Double, p95: Double) {
    let xs = (0..<runs).map { _ in ms(body) }.sorted()
    return (xs[xs.count / 2], xs[min(xs.count - 1, Int(Double(xs.count) * 0.95))])
}

func f(_ x: Double) -> String { x < 10 ? String(format: "%.2f", x) : String(format: "%.0f", x) }

var report: [String] = []
func row(_ cells: String...) { let line = "| " + cells.joined(separator: " | ") + " |"; print(line); report.append(line) }
func line(_ s: String = "") { print(s); report.append(s) }

// MARK: - synthetic corpus: 10 years of entries

let sentences = [
    "went to class and took notes all morning", "had ramen with mom and it was really cozy",
    "spent the evening alone in my room", "ran 5k before breakfast and felt amazing",
    "argued with my sister about something dumb", "my exam went badly and i'm worried about my grade",
    "finished a painting i've been working on for weeks", "rainy day so i stayed in bed and watched movies",
    "got coffee with friends and laughed so much", "couldn't sleep because of tomorrow's interview",
    "missed my grandma and looked at old photos", "baked cookies and burned half of them",
    "professor liked my essay which made my day", "walked around the city and took photos",
    "felt kind of numb and tired all day", "cleaned my whole room and it feels fresh",
    "worked a long shift and my feet hurt", "called an old friend and talked for hours",
]
var rng = RNG(state: 42)
var entries: [String: Entry] = [:]
let cal = Calendar(identifier: .gregorian)
let end = DiaryStore.date(fromKey: "2026-11-12")!
for back in 0..<3653 {
    let day = cal.date(byAdding: .day, value: -back, to: end)!
    var e = Entry()
    e.mood = Mood(rawValue: Int.random(in: 1...5, using: &rng))
    e.text = (0..<Int.random(in: 1...4, using: &rng)).map { _ in sentences.randomElement(using: &rng)! }.joined(separator: ". ") + "."
    entries[DiaryStore.key(day)] = e
}
let texts = entries.mapValues(\.text)
let words = texts.values.reduce(0) { $0 + $1.split(separator: " ").count }

line("## Benchmarks")
line()
line("Synthetic corpus: **\(entries.count) entries** (10 years, daily), \(words) words. " +
     "Machine: \(ProcessInfo.processInfo.processorCount)-core Apple silicon, release build.")
line()
row("operation", "p50", "p95")
row("---", "---:", "---:")

// MARK: - persistence

let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
var blob = Data()
let save = stats(15) { blob = try! enc.encode(entries) }
let load = stats(15) { _ = try! dec.decode([String: Entry].self, from: blob) }
row("save all entries (JSON encode, \(blob.count / 1024) KB)", f(save.p50) + " ms", f(save.p95) + " ms")
row("load all entries (JSON decode)", f(load.p50) + " ms", f(load.p95) + " ms")

// MARK: - insights

let coldInsights = ms { _ = Insights.compute(entries, today: end, calendar: cal) }
let warmInsights = stats(5) { _ = Insights.compute(entries, today: end, calendar: cal) }
row("insights, cold (sentiment for every entry)", f(coldInsights) + " ms", "–")
row("insights, warm (sentiment cached)", f(warmInsights.p50) + " ms", f(warmInsights.p95) + " ms")

// MARK: - semantic index

let serial = SemanticIndex()
serial.parallelism = 1
let buildSerial = ms { serial.sync(with: texts) }
let index = SemanticIndex()
let build = ms { index.sync(with: texts) }
row("build search index, 1 core (\(index.chunkCount) chunks × \(index.dimension)-d)", f(buildSerial) + " ms", "–")
row("build search index, \(index.parallelism) cores in parallel", f(build) + " ms", "–")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("diary-bench-\(getpid())")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
try! index.save(to: tmp)
let loadIndex = stats(10) { SemanticIndex().load(from: tmp) }
row("load saved index from disk (next launch)", f(loadIndex.p50) + " ms", f(loadIndex.p95) + " ms")
try? FileManager.default.removeItem(at: tmp)

var oneEntry = texts; oneEntry[DiaryStore.key(end)] = "a brand new entry about a long walk in the rain."
let incremental = ms { index.sync(with: oneEntry) }
row("re-index after editing one entry", f(incremental) + " ms", "–")

let queries = ["times i felt lonely", "stressed about school", "fun with friends", "food", "family",
               "creative projects", "exercise", "can't sleep", "proud of myself", "lazy day"]
let qv = index.vector("times i felt lonely")!
let blas = stats(200) { _ = index.similarities(qv) }
let naive = stats(50) { _ = index.similaritiesNaive(qv) }
row("similarity vs all chunks: Accelerate BLAS (sgemv)", f(blas.p50) + " ms", f(blas.p95) + " ms")
row("similarity vs all chunks: plain Swift loop", f(naive.p50) + " ms", f(naive.p95) + " ms")

var qi = 0
let endToEnd = stats(100) { _ = index.search(queries[qi % queries.count]); qi += 1 }
row("**semantic search, end to end** (embed query + rank)", "**" + f(endToEnd.p50) + " ms**", f(endToEnd.p95) + " ms")
let keyword = stats(100) { let q = queries[qi % queries.count]; qi += 1; _ = texts.filter { $0.value.contains(q) } }
row("keyword search (substring scan), for comparison", f(keyword.p50) + " ms", f(keyword.p95) + " ms")
line()
line(String(format: "Accelerate is **%.1f×** faster than the plain loop for the similarity step. ", naive.p50 / blas.p50) +
     String(format: "Parallel embedding builds the index **%.1f×** faster; after that, launches load the saved index in %@ ms instead of re-embedding.",
            buildSerial / build, f(loadIndex.p50)))
line()

// MARK: - retrieval quality

let docs = [
    "i spent the whole evening alone in my room and nobody texted me back",
    "went to the beach with friends and we laughed so much",
    "my exam went terribly and i think i failed chemistry",
    "had ramen with mom, it was cozy",
    "i couldn't sleep, kept worrying about tomorrow's interview",
    "finished my painting finally, so proud of it",
    "ran 5k this morning and my legs are dead but i feel great",
    "got into a huge argument with my sister and we're not talking",
    "rainy day, stayed in bed watching movies",
    "my professor praised my essay in front of the whole class",
    "missed my grandma today, looked at old photos of her",
    "baked cookies and burned half of them lol",
]
let labelled: [(String, Set<Int>)] = [
    ("times i felt lonely", [0]), ("stressed about school", [2]), ("fun with friends", [1]),
    ("anxious", [4]), ("food", [3, 11]), ("creative stuff", [5]), ("working out", [6]),
    ("fighting with family", [7]), ("doing nothing", [8]), ("proud of school", [9]),
    ("missing someone", [10]), ("good grades", [9]), ("sad about family", [10, 7]),
]
let small = SemanticIndex()
small.sync(with: Dictionary(uniqueKeysWithValues: docs.indices.map { (String($0), docs[$0]) }))

func evaluate(_ rank: (String) -> [Int]) -> (mrr: Double, top1: Int) {
    var total = 0.0, top1 = 0
    for (q, relevant) in labelled {
        let r = (rank(q).firstIndex { relevant.contains($0) } ?? docs.count) + 1
        total += 1 / Double(r); if r == 1 { top1 += 1 }
    }
    return (total / Double(labelled.count), top1)
}
let kw = evaluate { q in
    let qw = Set(SemanticIndex.contentWords(q))
    return docs.indices.sorted { a, b in
        let sa = SemanticIndex.contentWords(docs[a]).filter(qw.contains).count
        let sb = SemanticIndex.contentWords(docs[b]).filter(qw.contains).count
        return sa != sb ? sa > sb : a < b
    }
}
let sem = evaluate { q in
    let hits = small.search(q, limit: docs.count, minScore: -1).compactMap { Int($0.key) }
    return hits + docs.indices.filter { !hits.contains($0) }
}
line("## Search quality")
line()
line("\(labelled.count) hand-labelled queries over \(docs.count) diary-style entries " +
     "(queries mostly share no words with the right entry, e.g. *\"times i felt lonely\"* → *\"spent the evening alone…\"*).")
line()
row("method", "MRR", "top-1")
row("---", "---:", "---:")
row("keyword match", String(format: "%.2f", kw.mrr), "\(kw.top1)/\(labelled.count)")
row("**semantic (this app)**", String(format: "**%.2f**", sem.mrr), "**\(sem.top1)/\(labelled.count)**")

if CommandLine.arguments.count > 1 {
    try! (report.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
    print("\nwrote \(CommandLine.arguments[1])")
}

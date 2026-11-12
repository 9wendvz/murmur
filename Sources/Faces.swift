import SwiftUI
import AppKit

// MARK: - Face style model

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// A mood face: a plain coloured circle plus whatever you draw on it.
struct FaceStyle: Codable, Equatable {
    var label: String
    var color: RGB
    var drawing: [Stroke] = []

    init(label: String, color: RGB, drawing: [Stroke] = []) {
        self.label = label; self.color = color; self.drawing = drawing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        color = (try? c.decode(RGB.self, forKey: .color)) ?? RGB(0.8, 0.78, 0.72)
        drawing = (try? c.decodeIfPresent([Stroke].self, forKey: .drawing)) ?? []
    }

    static func defaults(for mood: Mood) -> FaceStyle {
        switch mood {
        case .rad:   return .init(label: "rad",   color: RGB(0.90, 0.74, 0.38))
        case .good:  return .init(label: "good",  color: RGB(0.67, 0.71, 0.50))
        case .meh:   return .init(label: "meh",   color: RGB(0.60, 0.71, 0.70))
        case .down:  return .init(label: "down",  color: RGB(0.73, 0.63, 0.66))
        case .awful: return .init(label: "awful", color: RGB(0.80, 0.52, 0.42))
        default:     return .init(label: "new", color: RGB(0.80, 0.72, 0.58))
        }
    }
}

// MARK: - Face store

final class FaceStore: ObservableObject {
    static let shared = FaceStore()

    @Published private(set) var styles: [Mood: FaceStyle] = [:]
    private let fileURL = DiaryStore.directory.appendingPathComponent("faces.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: FaceStyle].self, from: data) {
            for (k, v) in decoded { if let raw = Int(k), let m = Mood(rawValue: raw) { styles[m] = v } }
        }
    }

    func style(for mood: Mood) -> FaceStyle { styles[mood] ?? .defaults(for: mood) }

    /// Built-in faces best-first, then custom emotions in the order they were added.
    var allMoods: [Mood] { Mood.builtIn + styles.keys.filter { !$0.isBuiltIn }.sorted() }

    /// Adds a new, blank emotion and returns it.
    @discardableResult
    func addMood() -> Mood {
        let next = (styles.keys.map(\.rawValue).max() ?? 5) + 1
        let m = Mood(rawValue: max(6, next))!
        let colors = [RGB(0.85, 0.68, 0.66), RGB(0.60, 0.71, 0.70), RGB(0.55, 0.58, 0.42), RGB(0.88, 0.62, 0.42), RGB(0.73, 0.63, 0.66)]
        styles[m] = FaceStyle(label: "new", color: colors[m.rawValue % colors.count])
        save()
        return m
    }

    /// Deletes a custom emotion (built-in ones can't be deleted).
    func removeMood(_ mood: Mood) {
        guard !mood.isBuiltIn else { return }
        styles[mood] = nil
        save()
    }

    func update(_ mood: Mood, _ change: (inout FaceStyle) -> Void) {
        var s = style(for: mood)
        change(&s)
        styles[mood] = s
        save()
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: styles.map { (String($0.key.rawValue), $0.value) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(dict) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Drawing a face

/// Draws a face. `style == nil` draws an empty placeholder circle.
struct FaceView: View {
    let style: FaceStyle?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(style?.color.color ?? Theme.line.opacity(0.5))
            if let drawing = style?.drawing, !drawing.isEmpty {
                StrokesLayer(strokes: drawing).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

/// The face for a mood, using the user's own drawing.
struct MoodFace: View {
    @ObservedObject private var faces = FaceStore.shared
    let mood: Mood?
    var size: CGFloat = 40

    var body: some View {
        FaceView(style: mood.map { faces.style(for: $0) }, size: size)
    }
}

// MARK: - Face editor

struct FaceEditor: View {
    @ObservedObject private var faces = FaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mood: Mood = .rad
    @State private var pen = PenState(color: penColors[0], width: 0.035)
    @State private var confirmingDelete = false

    private let palette: [RGB] = [
        RGB(0.90, 0.74, 0.38), RGB(0.88, 0.62, 0.42), RGB(0.80, 0.52, 0.42), RGB(0.85, 0.68, 0.66),
        RGB(0.73, 0.63, 0.66), RGB(0.60, 0.71, 0.70), RGB(0.67, 0.71, 0.50), RGB(0.55, 0.58, 0.42),
        RGB(0.80, 0.72, 0.58), RGB(0.90, 0.87, 0.80), RGB(0.98, 0.96, 0.90), RGB(0.36, 0.33, 0.29),
    ]

    private var style: FaceStyle { faces.style(for: mood) }

    private var drawing: Binding<[Stroke]> {
        Binding(get: { style.drawing },
                set: { v in faces.update(mood) { $0.drawing = v } })
    }

    var body: some View {
        VStack(spacing: 22) {
            // which mood
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(faces.allMoods) { m in
                        VStack(spacing: 6) {
                            MoodFace(mood: m, size: 32)
                            Rectangle().fill(m == mood ? Theme.ink : .clear).frame(width: 12, height: 1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { mood = m } }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    Button("[+]") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { mood = faces.addMood() }
                    }
                    .buttonStyle(TextButtonStyle())
                    .help("add a new emotion")
                    .padding(.bottom, 7)
                }
                .padding(.horizontal, 4)
                .frame(minWidth: 364)
            }

            HStack(spacing: 6) {
                Text("name:").foregroundStyle(Theme.faint)
                TextField("untitled", text: Binding(
                    get: { style.label },
                    set: { v in faces.update(mood) { $0.label = String(v.prefix(18)) } }
                ))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.ink)
                .frame(width: 150)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 4) }
            }
            .font(Theme.font(13))

            DrawingPad(strokes: drawing, pen: pen) {
                Circle().fill(style.color.color)
            }
            .frame(width: 260, height: 260)
            .clipShape(Circle())
            .id(mood)
            .transition(.opacity)

            PenToolbar(pen: $pen, strokes: drawing, sizes: [0.02, 0.035, 0.055, 0.09])

            HStack(spacing: 8) {
                Text("face").foregroundStyle(Theme.faint).padding(.trailing, 4)
                ForEach(palette, id: \.self) { c in
                    Circle().fill(c.color).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                        .overlay(Circle().stroke(Theme.ink, lineWidth: style.color == c ? 1 : 0).padding(-3))
                        .onTapGesture { faces.update(mood) { $0.color = c } }
                }
            }

            HStack {
                if !mood.isBuiltIn {
                    Button("[delete]") { confirmingDelete = true }.buttonStyle(TextButtonStyle())
                }
                Spacer()
                Button("[done]") { dismiss() }
                    .buttonStyle(TextButtonStyle(active: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .font(Theme.font(12))
        .frame(width: 420)
        .background(Theme.paper)
        .confirmationDialog("delete \"\(style.label)\"?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let gone = mood
                withAnimation(.easeOut(duration: 0.25)) {
                    mood = .rad
                    DiaryStore.shared.clearMood(gone)
                    faces.removeMood(gone)
                }
            }
        } message: {
            Text("days marked with this emotion will be left without a mood.")
        }
    }
}

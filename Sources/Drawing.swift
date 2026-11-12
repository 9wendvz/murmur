import SwiftUI
import AppKit

// MARK: - Model

/// One pen stroke. Points and width are normalised to the canvas (0…1) so drawings scale to any size.
struct Stroke: Codable, Equatable {
    var points: [CGPoint]
    var color: RGB
    var width: Double
    var erase: Bool = false

    func path(in size: CGSize) -> Path {
        var p = Path()
        let pts = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 {
            p.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return p
        }
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }
}

struct PenState {
    var color: RGB
    var width: Double
    var erasing = false
}

let penColors: [RGB] = [
    RGB(0.235, 0.227, 0.216),  // sumi ink
    RGB(0.99, 0.98, 0.96),     // white
    RGB(0.498, 0.0, 0.098),    // deep red
    RGB(0.88, 0.50, 0.54),     // rose
    RGB(0.93, 0.76, 0.36),     // mustard
    RGB(0.50, 0.63, 0.45),     // moss
    RGB(0.38, 0.52, 0.72),     // indigo
    RGB(0.56, 0.42, 0.32),     // kraft brown
]

// MARK: - Views

struct StrokesLayer: View {
    let strokes: [Stroke]

    var body: some View {
        Canvas { ctx, size in
            for s in strokes {
                ctx.blendMode = s.erase ? .clear : .normal
                ctx.stroke(s.path(in: size), with: .color(s.color.color),
                           style: StrokeStyle(lineWidth: s.width * size.width, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Something you can draw on with the mouse or trackpad.
struct DrawingPad<Background: View>: View {
    @Binding var strokes: [Stroke]
    var pen: PenState
    @ViewBuilder var background: () -> Background

    @State private var current: Stroke?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background()
                StrokesLayer(strokes: current.map { strokes + [$0] } ?? strokes)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let p = CGPoint(x: round3(v.location.x / geo.size.width),
                                        y: round3(v.location.y / geo.size.height))
                        if current == nil {
                            current = Stroke(points: [p], color: pen.color,
                                             width: pen.erasing ? pen.width * 2.5 : pen.width,
                                             erase: pen.erasing)
                        } else if let last = current?.points.last, hypot(last.x - p.x, last.y - p.y) > 0.003 {
                            current?.points.append(p)
                        }
                    }
                    .onEnded { _ in
                        if let c = current { strokes.append(c) }
                        current = nil
                    }
            )
        }
    }

    private func round3(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }
}

/// Pen colours, sizes, eraser, undo, clear.
struct PenToolbar: View {
    @Binding var pen: PenState
    @Binding var strokes: [Stroke]
    let sizes: [Double]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                ForEach(penColors, id: \.self) { c in
                    Circle().fill(c.color)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
                        .overlay(Circle().stroke(Theme.ink, lineWidth: !pen.erasing && pen.color == c ? 1.2 : 0).padding(-3))
                        .contentShape(Circle())
                        .onTapGesture { pen.color = c; pen.erasing = false }
                }
            }
            HStack(spacing: 16) {
                ForEach(Array(sizes.enumerated()), id: \.offset) { i, w in
                    Circle().fill(!pen.erasing && pen.width == w ? Theme.ink : Theme.faint)
                        .frame(width: CGFloat(3 + i * 3), height: CGFloat(3 + i * 3))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { pen.width = w; pen.erasing = false }
                }
                Button("erase") { pen.erasing.toggle() }
                    .buttonStyle(TextButtonStyle(active: pen.erasing))
                Button("undo") { if !strokes.isEmpty { strokes.removeLast() } }
                    .buttonStyle(TextButtonStyle())
                    .keyboardShortcut("z", modifiers: .command)
                    .background {
                        // ctrl-Z as well (invisible twin of the undo button)
                        Button("") { if !strokes.isEmpty { strokes.removeLast() } }
                            .keyboardShortcut("z", modifiers: .control)
                            .opacity(0).frame(width: 0, height: 0)
                    }
                Button("clear") { strokes = [] }
                    .buttonStyle(TextButtonStyle())
            }
        }
    }
}

// MARK: - Doodle for an entry

struct DoodleSheet: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [Stroke] = []
    @State private var pen = PenState(color: penColors[0], width: 0.008)

    private let canvas = CGSize(width: 560, height: 420)

    var body: some View {
        VStack(spacing: 18) {
            DrawingPad(strokes: $strokes, pen: pen) { Theme.card }
                .frame(width: canvas.width, height: canvas.height)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))

            PenToolbar(pen: $pen, strokes: $strokes, sizes: [0.005, 0.009, 0.016, 0.03])

            HStack {
                Button("cancel") { dismiss() }.buttonStyle(TextButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("add") { save(); dismiss() }
                    .buttonStyle(TextButtonStyle(active: true))
                    .disabled(strokes.isEmpty)
                    .opacity(strokes.isEmpty ? 0.4 : 1)
            }
        }
        .padding(24)
        .background(Theme.paper)
    }

    private func save() {
        // transparent background, so the doodle sits on the page like ink; cropped to what was drawn
        let pts = strokes.filter { !$0.erase }.flatMap { s in s.points.map { (p: $0, w: s.width) } }
        guard !pts.isEmpty else { return }
        let pad = (pts.map(\.w).max() ?? 0.01) * canvas.width + 6
        let minX = max(0, pts.map { $0.p.x * canvas.width }.min()! - pad)
        let minY = max(0, pts.map { $0.p.y * canvas.height }.min()! - pad)
        let maxX = min(canvas.width, pts.map { $0.p.x * canvas.width }.max()! + pad)
        let maxY = min(canvas.height, pts.map { $0.p.y * canvas.height }.max()! + pad)
        let renderer = ImageRenderer(content:
            StrokesLayer(strokes: strokes)
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: -minX, y: -minY)
                .frame(width: maxX - minX, height: maxY - minY, alignment: .topLeading)
                .clipped()
        )
        renderer.isOpaque = false
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let name = UUID().uuidString + ".png"
        do {
            try png.write(to: DiaryStore.mediaDir.appendingPathComponent(name))
            var a = Attachment(kind: .photo, file: name)
            a.isDrawing = true
            DiaryStore.shared.addAttachment(a, for: date)
        } catch {}
    }
}

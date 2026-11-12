import SwiftUI
import IOKit.ps

// Small "hardware" details: crop marks, panel labels, screws, a battery readout and a boot screen.

/// L-shaped registration marks at each corner, like a technical drawing or a device faceplate.
struct CornerMarks: View {
    var length: CGFloat = 7
    var inset: CGFloat = -6

    var body: some View {
        GeometryReader { g in
            Path { p in
                let r = CGRect(origin: .zero, size: g.size).insetBy(dx: inset, dy: inset)
                for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                       (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + dx * length, y: y))
                    p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + dy * length))
                }
            }
            .stroke(Theme.faint, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A tiny uppercase label, like the silkscreen on a circuit board: "01 / CAL".
struct PanelLabel: View {
    let number: String
    let name: String

    var body: some View {
        Text("\(number) / \(name.uppercased())")
            .font(Theme.font(8))
            .tracking(1.5)
            .foregroundStyle(Theme.faint)
    }
}

/// A little flat-head screw.
struct Screw: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.paper).overlay(Circle().stroke(Theme.line, lineWidth: 1))
            Rectangle().fill(Theme.faint).frame(width: 4, height: 1).rotationEffect(.degrees(35))
        }
        .frame(width: 7, height: 7)
    }
}

extension View {
    /// Four screws in the corners.
    func screwed(inset: CGFloat = 7) -> some View {
        overlay(alignment: .topLeading) { Screw().padding(inset) }
            .overlay(alignment: .topTrailing) { Screw().padding(inset) }
            .overlay(alignment: .bottomLeading) { Screw().padding(inset) }
            .overlay(alignment: .bottomTrailing) { Screw().padding(inset) }
    }
}

// MARK: - Battery

enum Battery {
    /// (percent, charging) for the internal battery, or nil on a Mac without one.
    static func read() -> (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return (Int((Double(cur) / Double(max) * 100).rounded()), charging)
        }
        return nil
    }

    /// "BAT ▮▮▮▯ 82%" style readout.
    static func label() -> String? {
        guard let (pct, charging) = read() else { return nil }
        let bars = Int((Double(pct) / 25).rounded(.up))
        return "bat " + String(repeating: "▮", count: min(4, bars)) + String(repeating: "▯", count: max(0, 4 - bars))
            + " \(pct)%" + (charging ? "+" : "")
    }
}

// MARK: - Boot screen

/// A quick terminal-style start-up sequence with real numbers, then it fades away. Click to skip.
struct BootScreen: View {
    @Binding var done: Bool
    @State private var shown = 0

    private var lines: [(String, String)] {
        let store = DiaryStore.shared
        let media = store.entries.values.reduce(0) { $0 + $1.attachments.count }
        return [
            ("diary.os", "v1.0"),
            ("mount ~/diary", "ok"),
            ("entries", "\(store.entries.count)"),
            ("media", "\(media)"),
            ("faces", "\(FaceStore.shared.allMoods.count)"),
            ("nlp model", SearchModel.shared.isAvailable ? "on-device" : "n/a"),
            ("next date", DatesStore.shared.next().map { d, when in
                let n = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: when).day ?? 0
                return d.title + " · " + (n == 0 ? "today" : "\(n)d")
            } ?? "none"),
            ("todo", "\(TodoStore.shared.open) open" + (TodoStore.shared.overdue > 0 ? " · \(TodoStore.shared.overdue) late" : "")),
            ("network", "none · local only"),
            ("", "ready"),
        ]
    }

    var body: some View {
        ZStack {
            Theme.paper
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.prefix(shown).enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 0) {
                        if l.0.isEmpty {
                            Text("> " + l.1).foregroundStyle(Theme.ink)
                        } else {
                            // label, then dot leaders clipped to a fixed column so every value lines up
                            HStack(spacing: 6) {
                                Text(l.0).foregroundStyle(Theme.sub).fixedSize()
                                Text(String(repeating: ".", count: 40)).foregroundStyle(Theme.line)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).clipped()
                            }
                            .frame(width: 200, alignment: .leading)
                            Text("  " + l.1).foregroundStyle(i == 0 ? Theme.ink : Theme.sub)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .font(Theme.font(12))
            .frame(width: 300, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            for i in 1...lines.count {
                try? await Task.sleep(nanoseconds: 90_000_000)
                withAnimation(.easeOut(duration: 0.12)) { shown = i }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            finish()
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.35)) { done = true }
    }
}

// MARK: - More hardware

/// Faint perfboard dot grid, like the protoboard inside a DIY deck.
struct PerfBoard: View {
    var pitch: CGFloat = 14
    var body: some View {
        Canvas { ctx, size in
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(Theme.line.opacity(0.55)))
                    x += pitch
                }
                y += pitch
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small square LED.
struct LED: View {
    var on: Bool
    var color: Color = Theme.green
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(on ? color : Theme.line)
            .frame(width: 5, height: 5)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: 2.5)
    }
}

/// A tiny keycap showing a shortcut.
struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(Theme.font(8))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.line, lineWidth: 1))
            .offset(y: 1)
    }
}

/// Three-position switch: write (calendar + page) / feed (calendar + posts) / find (search + page), each with an LED.
struct ModeSwitch: View {
    @ObservedObject private var nav = AppNav.shared

    var body: some View {
        HStack(spacing: 14) {
            position("write", "⌘0", on: !nav.feed && !nav.searching && !nav.todo) { nav.feed = false; nav.searching = false; nav.todo = false }
            position("feed", "⌘L", on: nav.feed && !nav.searching && !nav.todo) { nav.searching = false; nav.todo = false; nav.feed = true }
            position("find", "⌘F", on: nav.searching) { nav.todo = false; nav.searching = true }
            position("todo", "⌘J", on: nav.todo && !nav.searching) { nav.searching = false; nav.todo = true }
        }
    }

    private func position(_ name: String, _ key: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.28)) { action() } } label: {
            HStack(spacing: 6) {
                LED(on: on)
                Text(name)
            }
        }
        .buttonStyle(TextButtonStyle(active: on))
        .help("\(name)  \(key)")
    }
}

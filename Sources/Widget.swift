import SwiftUI
import AppKit

let widgetSize = NSSize(width: 276, height: 318)

/// The desktop widget: this month's faces at a glance, today's mood one click away.
struct WidgetView: View {
    @ObservedObject var store = DiaryStore.shared
    @ObservedObject var faces = FaceStore.shared
    @ObservedObject var dates = DatesStore.shared
    @ObservedObject var todo = TodoStore.shared
    /// Opens the app — on a given day, or on today when nil.
    var openApp: (Date?) -> Void

    @State private var monthOffset = 0
    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        // Re-render every minute so the date rolls over at midnight.
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(today: ctx.date)
        }
        .frame(width: widgetSize.width, height: widgetSize.height)
    }

    @ViewBuilder private func content(today: Date) -> some View {
        let month = cal.date(byAdding: .month, value: monthOffset, to: cal.date(from: cal.dateComponents([.year, .month], from: today))!)!
        let entry = store.entry(for: today)
        let logged = (cal.range(of: .day, in: .month, for: month) ?? 1..<2).filter {
            store.entry(for: cal.date(byAdding: .day, value: $0 - 1, to: month)!)?.mood != nil
        }.count

        VStack(alignment: .leading, spacing: 12) {
            // header
            HStack(spacing: 8) {
                Text(String(format: "%04d.%02d", cal.component(.year, from: month), cal.component(.month, from: month)))
                    .contentTransition(.numericText())
                Text("\(logged)d").foregroundStyle(Theme.faint)
                Spacer()
                Button("‹") { withAnimation(.easeOut(duration: 0.2)) { monthOffset -= 1 } }
                Button("›") { withAnimation(.easeOut(duration: 0.2)) { monthOffset += 1 } }.disabled(monthOffset >= 0)
                Button("[open]") { openApp(nil) }
            }
            .buttonStyle(TextButtonStyle())
            .font(Theme.font(11))

            // weekday letters + the month grid
            VStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                        Text(d).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                    }
                }
                .font(Theme.font(8))
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(Array(cells(month).enumerated()), id: \.offset) { _, day in
                        if let day { cell(day, today: today) } else { Color.clear.frame(height: 30) }
                    }
                }
                .id(month)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            // today: tap a face to log your mood without opening the app
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("today")
                    Spacer()
                    if todo.open > 0 { Text("[ ] \(todo.open)").foregroundStyle(todo.overdue > 0 ? Theme.amber : Theme.faint) }
                    if let (d, when) = dates.next(from: today) {
                        let n = cal.dateComponents([.day], from: cal.startOfDay(for: today), to: when).day ?? 0
                        Text("◆ " + (n == 0 ? d.title : "\(n)d")).foregroundStyle(n <= 3 ? Theme.amber : Theme.faint).lineLimit(1)
                    }
                }
                .font(Theme.font(9))
                .foregroundStyle(Theme.faint)
                HStack(spacing: 0) {
                    ForEach(Mood.picker.prefix(6)) { m in
                        let on = entry?.mood == m
                        MoodFace(mood: m, size: 24)
                            .scaleEffect(on ? 1.15 : 1)
                            .opacity(entry?.mood == nil || on ? 1 : 0.25)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .help(faces.style(for: m).label)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                    store.setMood(on ? nil : m, for: today)
                                }
                            }
                    }
                }
            }
        }
        .font(Theme.font(12))
        .padding(16)
        .foregroundStyle(Theme.ink)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper)
                PerfBoard(pitch: 12).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .environment(\.colorScheme, .light)
        .contextMenu {
            Button("Open Diary") { openApp(nil) }
            Button("Hide Widget") { NSApp.sendAction(Selector(("toggleWidget")), to: NSApp.delegate, from: nil) }
            Divider()
            Button("Quit Diary") { NSApp.terminate(nil) }
        }
    }

    private var weekdays: [String] {
        let s = cal.veryShortWeekdaySymbols.map { $0.lowercased() }
        let i = cal.firstWeekday - 1
        return Array(s[i...] + s[..<i])
    }

    private func cells(_ month: Date) -> [Date?] {
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: month)!.count
        return Array(repeating: nil, count: lead) + (0..<days).map { cal.date(byAdding: .day, value: $0, to: month)! }
    }

    @ViewBuilder private func cell(_ day: Date, today: Date) -> some View {
        let mood = store.entry(for: day)?.mood
        let isToday = cal.isDate(day, inSameDayAs: today)
        let future = day > today && !isToday
        let important = !dates.on(day).isEmpty
        ZStack {
            if let mood {
                MoodFace(mood: mood, size: 26)
            } else {
                Text("\(cal.component(.day, from: day))")
                    .font(Theme.font(9))
                    .foregroundStyle(isToday ? Theme.red : future ? Theme.line : Theme.faint)
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if isToday { Rectangle().fill(Theme.ink).frame(width: 10, height: 1).offset(y: 1) }
        }
        .overlay(alignment: .topTrailing) {
            if important { Text("◆").font(.system(size: 5)).foregroundStyle(Theme.amber).offset(x: -2) }
        }
        .contentShape(Rectangle())
        .help(DiaryStore.key(day) + (mood.map { "  " + faces.style(for: $0).label } ?? ""))
        .onTapGesture { if !future { openApp(day) } }
    }
}

/// A borderless window that lives on the desktop (behind normal windows), on every Space.
final class DesktopWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(openApp: @escaping (Date?) -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: widgetSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: widgetSize))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(size: widgetSize, radius: 14)

        let host = NSHostingView(rootView: WidgetView(openApp: openApp))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        contentView = blur

        if !setFrameUsingName("DiaryWidget") {
            if let screen = NSScreen.main?.visibleFrame {
                setFrameOrigin(NSPoint(x: screen.maxX - widgetSize.width - 24,
                                       y: screen.maxY - widgetSize.height - 24))
            }
        }
        let top = frame.maxY
        setContentSize(widgetSize)
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
        setFrameAutosaveName("DiaryWidget")
    }

    private static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

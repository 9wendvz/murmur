import AppKit
import SwiftUI
import ServiceManagement
import Combine

// `Diary --render-icon <dir>` writes the app icon PNGs (used by build.sh).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
    MainActor.assumeIsolated {
        renderIconSet(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}

struct IconView: View {
    /// The app icon is your own top face (the one you drew for the best mood), in its colour.
    /// If it hasn't been drawn yet, a simple built-in smile stands in.
    var style: FaceStyle = IconView.currentStyle

    static var currentStyle: FaceStyle {
        let mine = FaceStore.shared.style(for: .rad)
        return mine.drawing.contains { !$0.erase }
            ? mine
            : FaceStyle(label: "", color: mine.color, drawing: fallbackDrawing)
    }

    /// Used until you've drawn your own face.
    static let fallbackDrawing: [Stroke] = {
        let ink = RGB(0.169, 0.149, 0.125)
        let smile = stride(from: 0.0, through: 1.0, by: 0.1).map { t in
            CGPoint(x: 0.32 + 0.36 * t, y: 0.6 + 0.1 * sin(t * .pi))
        }
        return [
            Stroke(points: [CGPoint(x: 0.38, y: 0.42)], color: ink, width: 0.07),
            Stroke(points: [CGPoint(x: 0.62, y: 0.42)], color: ink, width: 0.07),
            Stroke(points: smile, color: ink, width: 0.045),
        ]
    }()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(Theme.paper)
                .frame(width: 824, height: 824)
            FaceView(style: style, size: 560)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// The icon as an image, for the Dock while the app runs.
@MainActor func renderIconImage(_ style: FaceStyle) -> NSImage? {
    let r = ImageRenderer(content: IconView(style: style))
    r.scale = 0.5
    guard let cg = r.cgImage else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
}

@MainActor func renderIconSet(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let renderer = ImageRenderer(content: IconView())
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            renderer.scale = CGFloat(base * scale) / 1024
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var iconWatch: AnyCancellable?
    var mainWindow: NSWindow!
    var widget: DesktopWidgetWindow!
    var widgetItem: NSMenuItem!
    var loginItem: NSMenuItem!

    private var widgetEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "widgetEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "widgetEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenu()
        // keep the Dock icon in step with your drawn face, even right after you redraw it
        iconWatch = FaceStore.shared.$styles
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated {
                // only once you've drawn your own face; otherwise keep the icon the app shipped with
                let drawn = FaceStore.shared.style(for: .rad).drawing.contains { !$0.erase }
                NSApp.applicationIconImage = drawn ? renderIconImage(IconView.currentStyle) : nil
            } }
        _ = SearchModel.shared   // start loading / building the search index in the background
        _ = DatesStore.shared    // roll yearly reminders forward

        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        mainWindow.title = "Diary"
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titleVisibility = .hidden
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        mainWindow.backgroundColor = Theme.nsPaper
        mainWindow.contentView = NSHostingView(rootView: MainView())
        // one undo history for the window: typing, stickers, moods and to-dos
        DiaryStore.emptyTrash()
        DiaryStore.shared.undoManager = mainWindow.undoManager
        TodoStore.shared.undoManager = mainWindow.undoManager
        installControlZ()
        mainWindow.center()
        mainWindow.setFrameAutosaveName("DiaryMain")
        // the page has a fixed width now; make sure a smaller window saved by an older version still fits it
        let minSize = NSSize(width: 330 + 1 + EntryEditor.pageWidth + 88, height: 560)
        mainWindow.contentMinSize = minSize
        if mainWindow.frame.width < minSize.width {
            var f = mainWindow.frame
            f.size.width = minSize.width
            mainWindow.setFrame(f, display: false)
        }

        widget = DesktopWidgetWindow { [weak self] day in
            if let day {
                AppNav.shared.selected = day
                AppNav.shared.month = day
                self?.showMain(today: false)
            } else {
                self?.showMain(today: true)
            }
        }
        if widgetEnabled { widget.orderFront(nil) }
        updateMenuStates()

        // Launched at login → stay quiet, just show the widget.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if launchedAtLogin && widgetEnabled {
            NSApp.setActivationPolicy(.accessory)      // just the widget: no Dock icon, no menu bar
        } else {
            showMain(today: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(today: false)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiaryStore.shared.saveNow()
    }

    func showMain(today: Bool) {
        if today { AppNav.shared.goToToday() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    @objc func editFaces() {
        showMain(today: false)
        AppNav.shared.editingFaces = true
    }

    @objc func searchAction() {
        showMain(today: false)
        withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.searching = true }
    }

    @objc func calendarAction() {
        showMain(today: false)
        withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.searching = false; AppNav.shared.feed = false; AppNav.shared.todo = false }
    }

    @objc func listAction() {
        showMain(today: false)
        withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.searching = false; AppNav.shared.feed = true }
    }

    @objc func todoAction() {
        showMain(today: false)
        withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.searching = false; AppNav.shared.todo = true }
    }

    @objc func datesAction() {
        showMain(today: false)
        AppNav.shared.showingDates = true
    }

    @objc func insightsAction() {
        showMain(today: false)
        AppNav.shared.showingInsights = true
    }

    @objc func prevDay() { withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.step(days: -1) } }
    @objc func nextDay() { withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.step(days: 1) } }
    @objc func today() { withAnimation(.easeOut(duration: 0.28)) { AppNav.shared.goToToday() } }

    @objc func setMood(_ sender: NSMenuItem) {
        guard let m = Mood(rawValue: sender.tag) else { return }
        let day = AppNav.shared.selected
        let on = DiaryStore.shared.entry(for: day)?.mood == m
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            DiaryStore.shared.setMood(on ? nil : m, for: day)
        }
    }

    // Show each face's own name in the Go menu.
    // Rebuild the mood items each time the Go menu opens: ⌘1–⌘9 follow the face order, custom emotions included.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(setMood(_:)) { menu.removeItem(item) }
        for (i, m) in Mood.picker.prefix(9).enumerated() {
            let name = FaceStore.shared.style(for: m).label
            let item = menu.addItem(withTitle: "Mood: " + (name.isEmpty ? "untitled" : name),
                                    action: #selector(setMood(_:)), keyEquivalent: "\(i + 1)")
            item.tag = m.rawValue
        }
    }

    /// Ctrl-Z / Ctrl-Shift-Z / Ctrl-Y as well as ⌘Z, for anyone used to other keyboards.
    private func installControlZ() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.control), !mods.contains(.command), !mods.contains(.option),
                  NSApp.keyWindow === self?.mainWindow,
                  let key = e.charactersIgnoringModifiers?.lowercased() else { return e }
            let redo = (key == "z" && mods.contains(.shift)) || (key == "y" && !mods.contains(.shift))
            let undo = key == "z" && !mods.contains(.shift)
            guard undo || redo else { return e }
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: self)
            return nil
        }
    }

    @objc func showMainAction() { showMain(today: false) }

    /// Closing the window leaves just the desktop widget running, out of the Dock and menu bar.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow, widgetEnabled else { return }
        DiaryStore.shared.saveNow()
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    @objc func toggleWidget() {
        widgetEnabled.toggle()
        if widgetEnabled { widget.orderFront(nil) } else { widget.orderOut(nil) }
        // never leave an invisible app behind: no widget + no window → back in the Dock
        if !widgetEnabled && !mainWindow.isVisible { showMain(today: false) }
        updateMenuStates()
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Diary manually in System Settings → General → Login Items."
            alert.runModal()
        }
        updateMenuStates()
    }

    @objc func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([DiaryStore.shared.fileURL])
    }

    private func updateMenuStates() {
        widgetItem?.state = widgetEnabled ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Diary", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Customize Faces…", action: #selector(editFaces), keyEquivalent: ",")
        appMenu.addItem(.separator())
        widgetItem = appMenu.addItem(withTitle: "Show Desktop Widget", action: #selector(toggleWidget), keyEquivalent: "d")
        widgetItem.keyEquivalentModifierMask = [.command, .shift]
        loginItem = appMenu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        appMenu.addItem(withTitle: "Show Diary File in Finder", action: #selector(revealData), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Diary", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Diary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let stamp = edit.addItem(withTitle: "Insert Timestamp", action: #selector(NotebookTextView.insertTimestamp(_:)), keyEquivalent: "t")
        stamp.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = edit
        main.addItem(editItem)

        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Previous Day", action: #selector(prevDay), keyEquivalent: "[")
        go.addItem(withTitle: "Next Day", action: #selector(nextDay), keyEquivalent: "]")
        go.addItem(withTitle: "Today", action: #selector(today), keyEquivalent: "t")
        go.addItem(withTitle: "Search…", action: #selector(searchAction), keyEquivalent: "f")
        go.addItem(withTitle: "Write", action: #selector(calendarAction), keyEquivalent: "0")
        go.addItem(withTitle: "Feed", action: #selector(listAction), keyEquivalent: "l")
        go.addItem(withTitle: "Insights", action: #selector(insightsAction), keyEquivalent: "i")
        go.addItem(withTitle: "Important Dates…", action: #selector(datesAction), keyEquivalent: "d")
        go.addItem(withTitle: "To-do", action: #selector(todoAction), keyEquivalent: "j")
        go.addItem(.separator())

        go.delegate = self
        menuNeedsUpdate(go)
        goItem.submenu = go
        main.addItem(goItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Diary", action: #selector(showMainAction), keyEquivalent: "1")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

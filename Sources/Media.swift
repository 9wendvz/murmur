import SwiftUI
import AppKit
import AVFoundation
import AVKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Picking files

enum MediaPicker {
    static func pick(for date: Date) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .audio]
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            DiaryStore.shared.importFiles(panel.urls, for: date)
        }
    }
}

// MARK: - Voice recording

final class VoiceRecorder: ObservableObject {
    static let shared = VoiceRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var file = ""
    private var date = Date()

    func toggle(for date: Date) { isRecording ? stop() : start(for: date) }

    private func start(for date: Date) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(for: date)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.begin(for: date) } }
            }
        default:
            let alert = NSAlert()
            alert.messageText = "Microphone access is off"
            alert.informativeText = "Turn on Diary in System Settings → Privacy & Security → Microphone."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func begin(for date: Date) {
        file = UUID().uuidString + ".m4a"
        self.date = date
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: DiaryStore.mediaDir.appendingPathComponent(file), settings: settings),
              r.record() else { return }
        AudioPlayback.shared.stop()
        recorder = r
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.elapsed = self?.recorder?.currentTime ?? 0
        }
    }

    func stop() {
        guard let r = recorder else { return }
        let length = r.currentTime
        r.stop()
        timer?.invalidate()
        recorder = nil
        isRecording = false
        let url = DiaryStore.mediaDir.appendingPathComponent(file)
        if length < 0.5 {
            try? FileManager.default.removeItem(at: url)
        } else {
            DiaryStore.shared.addAttachment(Attachment(kind: .audio, file: file), for: date)
        }
    }
}

// MARK: - Audio playback

final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var playing: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ a: Attachment) {
        if playing == a.id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: a.url) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = a.id
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Thumbnails

enum Thumbnailer {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for a: Attachment, maxPixels: Int = 320) async -> NSImage? {
        let key = "\(a.file)@\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var cg: CGImage?
        switch a.kind {
        case .photo:
            cg = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(a.url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: a.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            cg = try? await gen.image(at: .zero).image
        case .audio:
            return nil
        }
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Views

struct MediaThumb: View {
    let attachment: Attachment
    var size: CGFloat = 104
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.paperDeep)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
            if attachment.kind == .video {
                Text("▶").font(.system(size: 10)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .contentShape(Rectangle())
        .task(id: attachment.id) { image = await Thumbnailer.image(for: attachment) }
    }
}

struct VoiceChip: View {
    let attachment: Attachment
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var duration: TimeInterval = 0

    var body: some View {
        let on = playback.playing == attachment.id
        HStack(spacing: 8) {
            Text(on ? "■" : "▶").font(.system(size: 8)).foregroundStyle(Theme.ink).frame(width: 10)
            Text("voice").foregroundStyle(on ? Theme.ink : Theme.sub)
            Text(formatDuration(duration)).monospacedDigit().foregroundStyle(Theme.faint)
        }
        .font(Theme.font(12))
        .contentShape(Rectangle())
        .onTapGesture { playback.toggle(attachment) }
        .task(id: attachment.id) {
            duration = (try? AVAudioPlayer(contentsOf: attachment.url))?.duration ?? 0
        }
    }
}

struct MediaViewer: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.paperDeep
                if attachment.kind == .photo, let img = NSImage(contentsOf: attachment.url) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else if let player {
                    PlayerView(player: player)
                }
            }
            HStack {
                Button("show in finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
                    .buttonStyle(TextButtonStyle())
                Spacer()
                Button("done") { dismiss() }.buttonStyle(TextButtonStyle(active: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Theme.paper)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            if attachment.kind == .video {
                player = AVPlayer(url: attachment.url)
                player?.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// AppKit's video player (the one QuickTime uses), wrapped for SwiftUI.
/// (SwiftUI's own `VideoPlayer` crashes in apps built with the Command Line Tools.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
    }
}

// MARK: - Copying attachments

enum MediaClipboard {
    /// Puts a photo/video/voice memo on the clipboard as a file (works in Finder, Messages, back in Diary…),
    /// plus the image itself for photos (works in apps that paste pictures). The clipboard gets its own copy
    /// of the file, so cutting — which deletes the original — still leaves something to paste.
    @discardableResult
    static func copy(file src: URL, kind: Attachment.Kind, to pb: NSPasteboard = .general) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diary-clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let label = kind == .photo ? "photo" : kind == .video ? "video" : "voice"
        let dest = dir.appendingPathComponent("diary-\(label)-\(UUID().uuidString.prefix(6).lowercased()).\(src.pathExtension)")
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        var items: [NSPasteboardWriting] = [dest as NSURL]
        if kind == .photo, let img = NSImage(contentsOf: dest) { items.append(img) }
        pb.clearContents()
        pb.writeObjects(items)
        return dest
    }

    static func copy(_ a: Attachment) { copy(file: a.url, kind: a.kind) }
}

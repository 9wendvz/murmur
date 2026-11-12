import SwiftUI
import AVFoundation

/// Live camera: take a photo or record a video, and it's attached to the day as a sticker.
final class CameraModel: NSObject, ObservableObject {
    enum Mode { case photo, video }
    enum State: Equatable { case starting, ready, denied, noCamera }

    @Published var mode: Mode = .photo
    @Published private(set) var state: State = .starting
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var attached = 0
    @Published private(set) var flash = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "diary.camera")
    private var timer: Timer?
    private var date = Date()
    private var audioAdded = false

    func start(for date: Date) {
        self.date = date
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.configure() : (self.state = .denied) }
            }
        default: state = .denied
        }
    }

    func stop() {
        if recording { movieOutput.stopRecording() }
        queue.async { self.session.stopRunning() }
    }

    private func configure() {
        queue.async {
            guard let cam = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: cam) else {
                DispatchQueue.main.async { self.state = .noCamera }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            // mirror what's saved, so it matches the preview (like Photo Booth)
            for c in [self.photoOutput.connection(with: .video), self.movieOutput.connection(with: .video)].compactMap({ $0 })
            where c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.state = .ready }
        }
    }

    /// Microphone is only needed for video; ask the first time a recording starts.
    private func addAudioIfAllowed(_ then: @escaping () -> Void) {
        guard !audioAdded else { return then() }
        let add = {
            self.queue.async {
                if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
                   self.session.canAddInput(input) {
                    self.session.beginConfiguration(); self.session.addInput(input); self.session.commitConfiguration()
                }
                self.audioAdded = true
                DispatchQueue.main.async(execute: then)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: add()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in add() }
        default: audioAdded = true; then()        // record silent video
        }
    }

    // MARK: shutter

    func shutter() {
        guard state == .ready else { return }
        switch mode {
        case .photo:
            let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) : AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeIn(duration: 0.25)) { self.flash = false } }
        case .video:
            if recording { movieOutput.stopRecording(); return }
            addAudioIfAllowed {
                let url = DiaryStore.mediaDir.appendingPathComponent(UUID().uuidString + ".mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                self.recording = true
                self.elapsed = 0
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.elapsed = self.movieOutput.recordedDuration.seconds
                }
            }
        }
    }

    private func attach(_ kind: Attachment.Kind, file: String) {
        DiaryStore.shared.addAttachment(Attachment(kind: kind, file: file), for: date)
        attached += 1
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        let name = UUID().uuidString + "." + ext
        guard (try? data.write(to: DiaryStore.mediaDir.appendingPathComponent(name), options: .atomic)) != nil else { return }
        DispatchQueue.main.async { self.attach(.photo, file: name) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.recording = false
            // a recording stopped by closing the sheet still reports success with a usable file
            let ok = (error == nil) || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if ok, FileManager.default.fileExists(atPath: url.path), output.recordedDuration.seconds > 0.3 {
                self.attach(.video, file: url.lastPathComponent)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// The live picture.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        v.layer = layer
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

struct CameraSheet: View {
    let date: Date
    @StateObject private var cam = CameraModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("~/diary/camera")
                Spacer()
                if cam.attached > 0 { Text("\(cam.attached) attached ✓").foregroundStyle(Theme.green).transition(.opacity) }
                Button("[done]") { dismiss() }.buttonStyle(TextButtonStyle(active: true)).keyboardShortcut(.cancelAction)
            }
            .font(Theme.font(12))

            ZStack {
                Theme.ink
                switch cam.state {
                case .ready: CameraPreview(session: cam.session)
                case .starting: Text("starting camera…").foregroundStyle(Theme.faint)
                case .noCamera: Text("no camera found.").foregroundStyle(Theme.faint)
                case .denied:
                    VStack(spacing: 10) {
                        Text("camera access is off for diary.").foregroundStyle(Theme.faint)
                        Button("[open settings]") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                        }
                        .buttonStyle(TextButtonStyle())
                    }
                }
                if cam.flash { Color.white.opacity(0.85) }
                if cam.recording {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.red).frame(width: 7, height: 7)
                        Text("rec " + formatDuration(cam.elapsed)).monospacedDigit()
                    }
                    .font(Theme.font(11)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.4)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                }
            }
            .frame(width: 560, height: 420)
            .clipped()
            .screwed(inset: 8)

            HStack(spacing: 18) {
                mode("photo", .photo)
                mode("video", .video)
                Spacer()
                Button(action: cam.shutter) {
                    Text(cam.mode == .photo ? "[ ◉ snap ]" : cam.recording ? "[ ■ stop ]" : "[ ● rec ]")
                        .foregroundStyle(cam.recording ? Theme.red : Theme.ink)
                }
                .buttonStyle(TextButtonStyle(active: true))
                .keyboardShortcut(.space, modifiers: [])
                .disabled(cam.state != .ready)
                Keycap(key: "space")
            }
            .font(Theme.font(12))
        }
        .padding(24)
        .background(Theme.paper)
        .foregroundStyle(Theme.ink)
        .onAppear { cam.start(for: date) }
        .onDisappear { cam.stop() }
    }

    private func mode(_ name: String, _ m: CameraModel.Mode) -> some View {
        Button { if !cam.recording { cam.mode = m } } label: {
            HStack(spacing: 6) { LED(on: cam.mode == m); Text(name) }
        }
        .buttonStyle(TextButtonStyle(active: cam.mode == m))
    }
}

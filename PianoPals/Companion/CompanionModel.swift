import AVFoundation
import Combine
import SwiftUI

/// What the iPhone does in camera mode: run the back camera with hand tracking and stream the result to the iPad.
@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var cameraName = ""
    @Published private(set) var permissionDenied = false
    @Published private(set) var noCamera = false
    @Published var usingBackCamera = true

    let channel = CameraChannel(id: .overhead)
    let host = CompanionHost()
    private let encoder = PreviewEncoder()
    private var cancellables: Set<AnyCancellable> = []
    private var demoTask: Task<Void, Never>?
    private var started = false

    init() {
        host.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        channel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        let host = self.host
        channel.onHandFrame = { frame in host.send(frame: frame) }
        let encoder = self.encoder
        channel.previewHandler = { pixelBuffer in
            if let jpeg = encoder.jpeg(from: pixelBuffer) { host.send(previewJPEG: jpeg.data, width: jpeg.width, height: jpeg.height) }
        }
        host.onControl = { [weak self] rotation, flip in
            Task { @MainActor in
                self?.channel.manualRotation = rotation
                self?.channel.flipHorizontally = flip
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        host.start()
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard status == .authorized else { permissionDenied = true; return }
        openCamera()
    }

    func stop() {
        started = false
        demoTask?.cancel()
        channel.stop()
        host.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func switchCamera() {
        usingBackCamera.toggle()
        openCamera()
    }

    private func openCamera() {
        let position: AVCaptureDevice.Position = usingBackCamera ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video) else {
            noCamera = true
            startDemoIfRequested()
            return
        }
        noCamera = false
        cameraName = device.localizedName
        channel.stop()
        channel.start(device: device, preferredFPS: 30)
    }

    /// With no camera (Simulator) and `-demoHands YES`, pretend hands are sent so the whole link can be tested.
    private func startDemoIfRequested() {
        guard UserDefaults.standard.bool(forKey: "demoHands"), demoTask == nil else { return }
        let channel = self.channel
        let host = self.host
        demoTask = Task.detached {
            let region = DemoHandSource.region(firstNote: 36, lastNote: 96)
            let notes = [60, 62, 64, 65, 67, 65, 64, 62]
            var step = 0
            var lastPreview = 0.0
            let preview = DemoPreview.jpeg()
            while !Task.isCancelled {
                let now = HostClock.now
                let note = notes[(step / 30) % notes.count]
                let finger = Finger(rawValue: (note - 60) % 5 + 1) ?? .thumb
                let frame = DemoHandSource.playingFrame(channel: .overhead, note: note, finger: finger, side: .right, region: region, time: now)
                channel.publishSynthetic(frame: frame)
                if now - lastPreview > 0.2, let preview { lastPreview = now; host.send(previewJPEG: preview.data, width: preview.width, height: preview.height) }
                step += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
}

/// A simple picture standing in for the camera in the Simulator.
enum DemoPreview {
    static func jpeg() -> (data: Data, width: Int, height: Int)? {
        let size = CGSize(width: 480, height: 270)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.20, green: 0.17, blue: 0.30, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.9).setFill()
            for i in 0..<14 { context.fill(CGRect(x: CGFloat(i) * 34 + 3, y: 160, width: 30, height: 110)) }
            let text = "iPhone camera (demo)" as NSString
            text.draw(at: CGPoint(x: 14, y: 12), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white])
        }
        guard let data = image.jpegData(compressionQuality: 0.6) else { return nil }
        return (data, Int(size.width), Int(size.height))
    }
}

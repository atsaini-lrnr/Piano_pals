import AVFoundation
import Combine
import Foundation
import UIKit
import OSLog
import Vision

/// One independent capture pipeline: a camera → live preview + Vision hand tracking.
///
/// Each channel owns its own `AVCaptureSession` and serial queues, so the front/side camera and the overhead
/// iPhone are isolated from each other and process frames concurrently. All AVFoundation mutation happens on
/// `sessionQueue`; all Vision work happens on `outputQueue`; published state is only ever written on the main thread.
final class CameraChannel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case starting
        case running
        case noCamera
        case denied
        case interrupted
        case failed(String)
    }

    static let log = Logger(subsystem: "com.example.PianoPals", category: "camera")

    let id: CameraChannelID
    let session = AVCaptureSession()

    @Published private(set) var state: State = .idle {
        didSet {
            if oldValue != state { CameraChannel.log.info("[\(self.id.rawValue, privacy: .public)] state \(String(describing: self.state), privacy: .public)") }
        }
    }
    @Published private(set) var deviceInfo: CameraDeviceInfo?
    @Published private(set) var latestFrame: HandFrame?
    @Published private(set) var face: FaceExpression?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var videoSize = CGSize(width: 16, height: 9)
    /// Manual rotation (degrees) added on top of the automatic orientation, for overhead mounts.
    @Published var manualRotation = 0 { didSet { applyOrientation() } }
    /// Flips the picture left/right on top of the automatic mirroring.
    @Published var flipHorizontally = false { didSet { applyOrientation() } }

    /// True while this channel shows a nearby iPhone in camera mode instead of a local camera.
    @Published private(set) var isRemote = false
    /// The latest preview picture sent by the iPhone.
    @Published private(set) var remotePreview: UIImage?
    /// Optional: receives a frame's pixels (≈ 10 per second) on the output queue; used by the iPhone to send previews.
    var previewHandler: (@Sendable (CVPixelBuffer) -> Void)?
    /// Invoked on the output queue for every processed frame.
    var onHandFrame: (@Sendable (HandFrame) -> Void)?
    /// Whether to look for the child's face on this channel (front camera only).
    var wantsFaceExpression: Bool {
        get { config.current.detectFace }
        set { config.withLock { $0.detectFace = newValue } }
    }

    private struct ProcessingConfig {
        var mirrored = false
        var detectFace = false
    }

    private let config = Locked(ProcessingConfig())
    private let sessionQueue: DispatchQueue
    private let outputQueue: DispatchQueue
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processor: HandPoseProcessor
    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []
    private let previewLayers = NSHashTable<AVCaptureVideoPreviewLayer>.weakObjects()
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastPublishTime: TimeInterval = 0
    private var lastFaceTime: TimeInterval = 0
    private var lastPreviewTime: TimeInterval = 0
    private var lastRemotePublish: TimeInterval = 0
    private var statsWindowStart: TimeInterval = 0
    private var statsFrames = 0
    private var statsHandFrames = 0
    private var dumpedFrame = false
    private var targetFPS = 60.0
    /// Only touched on `outputQueue`.
    private var smoother = HandSmoother()

    init(id: CameraChannelID) {
        self.id = id
        self.sessionQueue = DispatchQueue(label: "pianopals.camera.\(id.rawValue).session")
        self.outputQueue = DispatchQueue(label: "pianopals.camera.\(id.rawValue).output", qos: .userInitiated)
        self.processor = HandPoseProcessor(channel: id)
        super.init()
        observeSession()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Control

    func setUnavailable(_ unavailable: State) {
        stop()
        state = unavailable
    }

    func start(device: AVCaptureDevice, preferredFPS: Double) {
        targetFPS = preferredFPS
        let info = CameraDeviceInfo(device: device)
        deviceInfo = info
        state = .starting
        currentDevice = device
        let mirroredByDefault = CameraDeviceInfo(device: device).kind == .front
        config.withLock { $0.mirrored = mirroredByDefault != flipHorizontally }
        setupRotationCoordinator(for: device)

        outputQueue.async { [weak self] in self?.smoother.reset() }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSession(with: device)
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.state = self.session.isRunning ? .running : .failed("The camera didn't start.")
                    self.applyOrientation()
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            if let input = self.currentInput { self.session.removeInput(input) }
            self.currentInput = nil
            self.session.commitConfiguration()
        }
        currentDevice = nil
        rotationCoordinator = nil
        rotationObservers.removeAll()
        deviceInfo = nil
        latestFrame = nil
        face = nil
        framesPerSecond = 0
        if state != .denied { state = .idle }
    }

    // MARK: Remote (iPhone in camera mode)

    func attachRemote(name: String) {
        stop()
        isRemote = true
        deviceInfo = CameraDeviceInfo(id: "companion", name: name, kind: .companion)
        videoSize = CGSize(width: 16, height: 9)
        state = .running
    }

    func detachRemote() {
        guard isRemote else { return }
        isRemote = false
        remotePreview = nil
        latestFrame = nil
        deviceInfo = nil
        state = .noCamera
    }

    func setRemotePreview(_ image: UIImage) {
        guard isRemote else { return }
        remotePreview = image
        if image.size.width > 0 { videoSize = CGSize(width: image.size.width, height: image.size.height) }
    }

    /// A frame from the iPhone. Safe to call from any queue; SwiftUI is updated at most ~30 times a second.
    func publishRemote(frame: HandFrame) {
        onHandFrame?(frame)
        guard frame.timestamp - lastRemotePublish >= 1.0 / 30.0 else { return }
        lastRemotePublish = frame.timestamp
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRemote else { return }
            self.latestFrame = frame
        }
    }

    /// Lets a synthetic source (demo hands) publish frames as if they came from this camera.
    func publishSynthetic(frame: HandFrame) {
        latestFrame = frame
        videoSize = frame.imageSize
        onHandFrame?(frame)
    }

    // MARK: Session configuration (sessionQueue)

    private func configureSession(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        currentInput = input

        if !session.outputs.contains(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
            session.addOutput(videoOutput)
        }
        try selectFormat(for: device)
    }

    /// Prefers the largest ≤ 1080p format that supports the target frame rate (60 fps if possible, else 30).
    private func selectFormat(for device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width <= 1920 && dimensions.height <= 1080 && dimensions.width >= 640
        }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        }
        let wanted = targetFPS
        let capable = candidates.filter { maxRate($0) >= wanted }
        let pool = capable.isEmpty ? candidates : capable
        guard let format = pool.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }) else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let rate = min(wanted, maxRate(format))
        let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    // MARK: Orientation

    private func setupRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservers.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayers.allObjects.first)
        rotationCoordinator = coordinator
        rotationObservers = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyOrientation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyOrientation() }
            }
        ]
    }

    func register(previewLayer: AVCaptureVideoPreviewLayer) {
        previewLayers.add(previewLayer)
        applyOrientation()
    }

    /// Main thread. Rotates / mirrors the preview and the data-output connection so Vision sees an upright picture.
    func applyOrientation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.applyOrientation() }
            return
        }
        let mirrored = (currentDevice.map { CameraDeviceInfo(device: $0).kind == .front } ?? false) != flipHorizontally
        config.withLock { $0.mirrored = mirrored }

        let previewBase = Double(rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0)
        let captureBase = Double(rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0)
        let previewAngle = CGFloat(RotationMath.combined(base: previewBase, manual: manualRotation))
        let captureAngle = CGFloat(RotationMath.combined(base: captureBase, manual: manualRotation))

        for layer in previewLayers.allObjects {
            layer.videoGravity = .resizeAspectFill
            guard let connection = layer.connection else { continue }
            if connection.isVideoRotationAngleSupported(previewAngle) { connection.videoRotationAngle = previewAngle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.videoOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(captureAngle) { connection.videoRotationAngle = captureAngle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }

    // MARK: Session notifications

    private func observeSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.state = .interrupted
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.state = .running
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            guard let self, self.currentDevice != nil else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset {
                self.sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
            } else {
                self.state = .failed(error?.localizedDescription ?? "The camera stopped unexpectedly.")
            }
        })
    }

    #if DEBUG
    /// Average brightness (0–255) sampled from the luma plane; ~0 means a black picture.
    static func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferIsPlanar(pixelBuffer), let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return -1 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var total = 0.0, count = 0.0
        for y in Swift.stride(from: 0, to: height, by: 40) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 40) { total += Double(row[x]); count += 1 }
        }
        return count > 0 ? total / count : -1
    }

    /// Debug aid: logs frames/s and hands seen, and (with `-debugDumpFrame YES`) saves one frame to Documents/frame-<channel>.jpg
    /// so it can be fetched from a real device and inspected.
    private func debugStats(timestamp: TimeInterval, pixelBuffer: CVPixelBuffer) {
        if statsWindowStart == 0 { statsWindowStart = timestamp }
        statsFrames += 1
        if timestamp - statsWindowStart >= 2 {
            let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
            CameraChannel.log.info("[\(self.id.rawValue, privacy: .public)] \(Double(self.statsFrames) / (timestamp - self.statsWindowStart), format: .fixed(precision: 1)) fps, buffer \(width)x\(height) format \(CVPixelBufferGetPixelFormatType(pixelBuffer)), mean luma \(CameraChannel.meanLuma(pixelBuffer), format: .fixed(precision: 1)), device \(self.currentDevice?.localizedName ?? "?", privacy: .public) [\(self.currentDevice?.deviceType.rawValue ?? "?", privacy: .public)] format \(self.currentDevice?.activeFormat.description ?? "?", privacy: .public), hands: \(self.latestFrame?.hands.count ?? -1)")
            statsWindowStart = timestamp
            statsFrames = 0
        }
        if !dumpedFrame, UserDefaults.standard.bool(forKey: "debugDumpFrame"), timestamp - statsWindowStart > 1, let jpeg = PreviewEncoder().jpeg(from: pixelBuffer) {
            dumpedFrame = true
            let url = URL.documentsDirectory.appending(path: "frame-\(id.rawValue).jpg")
            try? jpeg.data.write(to: url)
            CameraChannel.log.info("[\(self.id.rawValue, privacy: .public)] saved debug frame \(jpeg.width)x\(jpeg.height) to \(url.lastPathComponent, privacy: .public)")
        }
    }
    #endif

    // MARK: Frames (outputQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let settings = config.current

        // The face request is cheap but not free: sample it at ~8 Hz.
        let detectFace = settings.detectFace && timestamp - lastFaceTime >= 0.12
        if detectFace { lastFaceTime = timestamp }

        #if DEBUG
        debugStats(timestamp: timestamp, pixelBuffer: pixelBuffer)
        #endif
        var result = processor.process(pixelBuffer: pixelBuffer, timestamp: timestamp, mirrored: settings.mirrored, detectFace: detectFace)
        result.hands = smoother.smooth(result.hands)
        onHandFrame?(result.hands)

        if let handler = previewHandler, timestamp - lastPreviewTime >= 0.1 {
            lastPreviewTime = timestamp
            handler(pixelBuffer)
        }

        // Publish to SwiftUI at most ~30 times a second.
        guard timestamp - lastPublishTime >= 1.0 / 30.0 else { return }
        lastPublishTime = timestamp
        let fps = processor.framesPerSecond
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestFrame = result.hands
            if self.videoSize != result.hands.imageSize { self.videoSize = result.hands.imageSize }
            self.framesPerSecond = fps
            if detectFace { self.face = result.face }
        }
    }
}

enum CameraError: LocalizedError {
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "This camera can't be used right now. Is another app using it?"
        case .cannotAddOutput: return "The camera's video couldn't be read."
        }
    }
}

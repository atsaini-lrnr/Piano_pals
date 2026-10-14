#if DEBUG
import AVFoundation
import OSLog
import UIKit

/// Debug-only: the simplest possible capture session (default preset, no custom format, no rotation), to tell whether a black
/// picture comes from the app's capture pipeline or from the device/system. `-debugRawCamera front|back`.
final class RawCameraProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "probe")
    private var frames = 0
    private var lastLog = Date()
    private let log = Logger(subsystem: "com.example.PianoPals", category: "camera")

    func start(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { log.info("probe: no device"); return }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [log] note in
            log.info("probe: INTERRUPTED \(String(describing: note.userInfo), privacy: .public)")
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [log] note in
            log.info("probe: RUNTIME ERROR \(String(describing: note.userInfo), privacy: .public)")
        }
        DispatchQueue.global().async { [session, log] in
            session.startRunning()
            log.info("probe: started \(device.localizedName, privacy: .public))")
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        log.info("probe: app state \(UIApplication.shared.applicationState.rawValue) (0 = active); device suspended=\(device.isSuspended) connected=\(device.isConnected) center-stage=\(AVCaptureDevice.isCenterStageEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) window=\(String(describing: window?.coordinateSpace.bounds)) screen=\(String(describing: window?.screen.bounds)) fullscreen=\(window?.isFullScreen ?? false) sceneActivation=\(window?.activationState.rawValue ?? -1)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard Date().timeIntervalSince(lastLog) > 2, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastLog = Date()
        let luma = CameraChannel.meanLuma(pixelBuffer)
        let state = DispatchQueue.main.sync { UIApplication.shared.applicationState.rawValue }
        log.info("probe: \(self.frames) frames, mean luma \(luma, format: .fixed(precision: 1)), app state \(state)")
    }
}
#endif

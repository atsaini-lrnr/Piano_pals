import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVCaptureVideoPreviewLayer` for one camera channel.
struct CameraPreviewView: UIViewRepresentable {
    let channel: CameraChannel
    /// `.resizeAspectFill` crops to fill the view; `.resizeAspect` shows the whole picture with bars.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = channel.session
        view.previewLayer.videoGravity = gravity
        channel.register(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== channel.session { uiView.previewLayer.session = channel.session }
        uiView.previewLayer.videoGravity = gravity
        channel.register(previewLayer: uiView.previewLayer)
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

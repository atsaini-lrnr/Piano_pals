import SwiftUI

/// The overhead camera, cropped and scaled so every real key sits directly above its on-screen key. Finger dots and the coaching
/// markers use the same mapping, so they line up too. With "footage" off, a drawn keyboard replaces the picture.
struct AlignedCameraStrip: View {
    @ObservedObject var channel: CameraChannel
    let crop: AlignedCrop
    let span: KeyboardSpan
    let region: KeyboardRegion
    let showFootage: Bool
    var highlight: Finger?
    var coaching: CoachingContext?

    private var pictureSize: CGSize { channel.latestFrame?.imageSize ?? channel.videoSize }
    private var hasPicture: Bool { channel.isRemote ? channel.remotePreview != nil : channel.state == .running }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if showFootage, hasPicture {
                    footage(in: geo.size)
                } else {
                    StylizedKeysView(span: span, region: region, crop: crop)
                }
                HandOverlayView(frame: channel.latestFrame, highlight: highlight, crop: crop)
                if let coaching {
                    CoachingOverlayView(frame: channel.latestFrame, context: coaching, imageSize: pictureSize, crop: crop)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .aspectRatio(crop.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white, lineWidth: 4))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera lined up with the keys")
    }

    /// The whole picture, placed so that `crop.rect` exactly fills the strip.
    private func footage(in view: CGSize) -> some View {
        let frameWidth = view.width / crop.rect.width
        let frameHeight = frameWidth * pictureSize.height / max(pictureSize.width, 1)
        let leftEdge = crop.flipX ? 1 - crop.rect.maxX : crop.rect.minX
        return Group {
            if channel.isRemote, let image = channel.remotePreview {
                Image(uiImage: image).resizable()
            } else {
                CameraPreviewView(channel: channel, gravity: .resizeAspect)
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .scaleEffect(x: crop.flipX ? -1 : 1, y: 1)
        .offset(x: -leftEdge * frameWidth, y: -crop.rect.minY * frameHeight)
        .frame(width: view.width, height: view.height, alignment: .topLeading)
    }
}

/// A drawn keyboard strip (no footage): white and black keys at exactly the on-screen keyboard's x positions.
struct StylizedKeysView: View {
    let span: KeyboardSpan
    let region: KeyboardRegion
    let crop: AlignedCrop

    var body: some View {
        Canvas { canvas, size in
            canvas.fill(Path(CGRect(origin: .zero, size: size)),
                        with: .linearGradient(Gradient(colors: [Color(red: 0.21, green: 0.18, blue: 0.34), Color(red: 0.11, green: 0.10, blue: 0.22)]),
                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let top = min(max((region.yMin - crop.rect.minY) / crop.rect.height, 0), 1) * size.height
            let bottom = min(max((region.yMax - crop.rect.minY) / crop.rect.height, 0), 1) * size.height
            let whiteWidth = size.width / CGFloat(max(span.whiteKeyCount, 1))
            for note in span.notes where !PianoKeys.isBlack(note) {
                let x = CGFloat(PianoKeys.whiteIndex(note) - span.firstWhiteIndex) * whiteWidth
                canvas.fill(Path(roundedRect: CGRect(x: x + 1.5, y: top, width: whiteWidth - 3, height: max(bottom - top, 8)), cornerRadius: 6),
                            with: .color(.white.opacity(0.92)))
            }
            for note in span.notes where PianoKeys.isBlack(note) {
                let centre = CGFloat(PianoKeys.center(of: note) - Double(span.firstWhiteIndex)) * whiteWidth
                canvas.fill(Path(roundedRect: CGRect(x: centre - whiteWidth * 0.3, y: top, width: whiteWidth * 0.6, height: max(bottom - top, 8) * 0.62), cornerRadius: 4),
                            with: .color(Color(red: 0.13, green: 0.12, blue: 0.28)))
            }
        }
        .accessibilityHidden(true)
    }
}

import CoreGraphics

/// Where a point of the camera picture lands on screen.
///
/// A preview shown "aspect fill" is scaled up until it covers the view, which crops the picture; one shown "aspect fit" is scaled
/// down until it all fits, which leaves bars. Overlays (finger dots, key markers) must apply the same scale and offset or they
/// drift away from what they mark.
enum OverlayGeometry {
    /// `point` is normalised (0…1, top-left origin) within the picture.
    static func viewPoint(_ point: CGPoint, imageSize: CGSize, viewSize: CGSize, fit: Bool) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGPoint(x: point.x * viewSize.width, y: point.y * viewSize.height)
        }
        let scale = fit ? min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
                        : max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let shownWidth = imageSize.width * scale
        let shownHeight = imageSize.height * scale
        let originX = (viewSize.width - shownWidth) / 2
        let originY = (viewSize.height - shownHeight) / 2
        return CGPoint(x: originX + point.x * shownWidth, y: originY + point.y * shownHeight)
    }
}

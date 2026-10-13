import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes camera frames as small JPEGs for the companion preview.
final class PreviewEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    var targetWidth: CGFloat = 480
    var quality: CGFloat = 0.5

    func jpeg(from pixelBuffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, targetWidth / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let data = context.jpegRepresentation(of: scaled, colorSpace: colorSpace,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]) else { return nil }
        return (data, Int(scaled.extent.width), Int(scaled.extent.height))
    }
}

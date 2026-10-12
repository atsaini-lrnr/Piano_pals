import AVFoundation
import Foundation

/// A camera the app can show, described without holding on to the AVFoundation object.
struct CameraDeviceInfo: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case front
        case back
        case ultraWide
        case continuity
        case external
        case other
    }

    let id: String
    let name: String
    let kind: Kind

    /// Built-in cameras can't run two at once (outside multi-cam sessions), so only one channel may use one.
    var isBuiltIn: Bool { kind == .front || kind == .back || kind == .ultraWide }
    var isRemote: Bool { kind == .continuity || kind == .external }

    var symbolName: String {
        switch kind {
        case .front: return "ipad.badge.person.crop"
        case .back: return "camera"
        case .ultraWide: return "camera.aperture"
        case .continuity: return "iphone.gen3"
        case .external: return "web.camera"
        case .other: return "video"
        }
    }

    var kindDescription: String {
        switch kind {
        case .front: return "iPad front camera"
        case .back: return "iPad back camera"
        case .ultraWide: return "iPad ultra-wide camera"
        case .continuity: return "iPhone (Continuity Camera)"
        case .external: return "External camera"
        case .other: return "Camera"
        }
    }

    init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    init(device: AVCaptureDevice) {
        let kind: Kind
        if device.isContinuityCamera || device.deviceType == .continuityCamera {
            kind = .continuity
        } else if device.deviceType == .external {
            kind = .external
        } else if device.deviceType == .builtInUltraWideCamera {
            kind = .ultraWide
        } else {
            switch device.position {
            case .front: kind = .front
            case .back: kind = .back
            default: kind = .other
            }
        }
        self.init(id: device.uniqueID, name: device.localizedName, kind: kind)
    }
}

enum CameraLayout: String, CaseIterable, Identifiable {
    case grid
    case pip

    var id: String { rawValue }
    var displayName: String { self == .grid ? "Side by side" : "Picture in picture" }
}

enum TrackingPreference: String, CaseIterable, Identifiable {
    case automatic
    case primary
    case overhead

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic (overhead if available)"
        case .primary: return "Front / side camera"
        case .overhead: return "Overhead camera"
        }
    }
}

/// Normalises a rotation in degrees to one of 0 / 90 / 180 / 270.
enum RotationMath {
    static func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return (value / 90).rounded() * 90 == 360 ? 0 : (value / 90).rounded() * 90
    }

    /// Combines the automatic (gravity-based) angle with the grown-up's manual rotation.
    static func combined(base: Double, manual: Int) -> Double { normalized(base + Double(manual)) }
}

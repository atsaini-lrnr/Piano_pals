import Foundation
import QuartzCore

/// All timestamps in the app (MIDI packets, camera frames, UI events) use the mach host clock in seconds,
/// so a key strike and the video frame it landed in can be compared directly.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: TimeInterval { CACurrentMediaTime() }

    /// Converts mach absolute-time ticks (as used by CoreMIDI) to seconds on the same clock as `now`.
    static func seconds(fromTicks ticks: UInt64) -> TimeInterval {
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

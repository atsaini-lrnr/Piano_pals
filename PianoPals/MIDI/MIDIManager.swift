import Combine
import CoreMIDI
import Foundation

struct MIDISourceInfo: Identifiable, Equatable {
    let id: MIDIUniqueID
    let name: String
}

/// Discovers every CoreMIDI source (USB-C keyboards, Bluetooth LE MIDI, network sessions), connects to it
/// automatically, and publishes parsed Note-On / Note-Off events.
final class MIDIManager: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var sources: [MIDISourceInfo] = []
    /// Notes currently held down (hardware and on-screen).
    @Published private(set) var pressedNotes: Set<UInt8> = []
    @Published private(set) var eventCount = 0

    /// Every note event, delivered on the main queue.
    let noteEvents = PassthroughSubject<MIDINoteEvent, Never>()

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedEndpoints: [MIDIUniqueID: MIDIEndpointRef] = [:]

    var isKeyboardConnected: Bool { !sources.isEmpty }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: Lifecycle

    func start() {
        guard status != .running else { return }

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("PianoPals" as CFString, &newClient) { [weak self] notification in
            let id = notification.pointee.messageID
            guard id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved else { return }
            DispatchQueue.main.async { self?.refreshSources() }
        }
        guard clientStatus == noErr else {
            status = .failed("Couldn't start MIDI (error \(clientStatus)).")
            return
        }

        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(newClient, "PianoPals Input" as CFString, ._1_0, &newPort) { [weak self] eventList, _ in
            let timestamp = HostClock.now
            let events = MIDIManager.decode(eventList: eventList, fallbackTimestamp: timestamp)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self?.deliver(events) }
        }
        guard portStatus == noErr else {
            MIDIClientDispose(newClient)
            status = .failed("Couldn't open a MIDI input (error \(portStatus)).")
            return
        }

        client = newClient
        inputPort = newPort
        status = .running
        refreshSources()
    }

    func stop() {
        for (_, endpoint) in connectedEndpoints { MIDIPortDisconnectSource(inputPort, endpoint) }
        connectedEndpoints.removeAll()
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        sources = []
        pressedNotes = []
        status = .stopped
    }

    // MARK: Source discovery

    /// Reconnects to whatever is currently plugged in and drops sources that have gone away.
    func refreshSources() {
        guard status == .running else { return }

        var present: [MIDIUniqueID: (endpoint: MIDIEndpointRef, name: String)] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { continue }
            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            present[uniqueID] = (endpoint, MIDIManager.displayName(of: endpoint))
        }

        let removed = connectedEndpoints.keys.filter { present[$0] == nil }
        for id in removed {
            if let endpoint = connectedEndpoints[id] { MIDIPortDisconnectSource(inputPort, endpoint) }
            connectedEndpoints[id] = nil
        }
        for (id, source) in present where connectedEndpoints[id] == nil {
            if MIDIPortConnectSource(inputPort, source.endpoint, nil) == noErr {
                connectedEndpoints[id] = source.endpoint
            }
        }

        let updated = connectedEndpoints.keys
            .compactMap { id in present[id].map { MIDISourceInfo(id: id, name: $0.name) } }
            .sorted { $0.name < $1.name }
        if updated != sources { sources = updated }
        if !removed.isEmpty {
            // A keyboard that was unplugged mid-note would otherwise leave keys "stuck" down.
            pressedNotes = []
        }
    }

    // MARK: Events

    /// Feeds an on-screen key press through exactly the same path as a hardware key.
    func injectOnScreen(note: UInt8, isOn: Bool, velocity: UInt8 = 80) {
        let event = MIDINoteEvent(note: note, velocity: isOn ? velocity : 0, isOn: isOn, channel: 0,
                                  timestamp: HostClock.now, origin: .onScreen)
        deliver([event])
    }

    private func deliver(_ events: [MIDINoteEvent]) {
        for event in events {
            if event.isOn { pressedNotes.insert(event.note) } else { pressedNotes.remove(event.note) }
            eventCount += 1
            noteEvents.send(event)
        }
    }

    // MARK: CoreMIDI plumbing

    private static func displayName(of object: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr, let value = name?.takeRetainedValue() {
            return value as String
        }
        return "MIDI Device"
    }

    /// Walks the packets of a `MIDIEventList` and decodes their UMP words.
    private static func decode(eventList: UnsafePointer<MIDIEventList>, fallbackTimestamp: TimeInterval) -> [MIDINoteEvent] {
        var events: [MIDINoteEvent] = []
        let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet) ?? 8
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) ?? 8
        var packetPointer = UnsafeRawPointer(eventList).advanced(by: packetOffset)

        for _ in 0..<eventList.pointee.numPackets {
            let packet = packetPointer.assumingMemoryBound(to: MIDIEventPacket.self)
            let wordCount = Int(packet.pointee.wordCount)
            let timestamp = packet.pointee.timeStamp == 0 ? fallbackTimestamp : HostClock.seconds(fromTicks: packet.pointee.timeStamp)
            let wordsPointer = packetPointer.advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            let words = Array(UnsafeBufferPointer(start: wordsPointer, count: wordCount))
            events.append(contentsOf: MIDIParser.parse(words: words, timestamp: timestamp))

            // Packets are variable length: advance past the fixed header plus the words actually present.
            let packetSize = wordsOffset + wordCount * MemoryLayout<UInt32>.size
            let aligned = (packetSize + 3) & ~3
            packetPointer = packetPointer.advanced(by: aligned)
        }
        return events
    }
}

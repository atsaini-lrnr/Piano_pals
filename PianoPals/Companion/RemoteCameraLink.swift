import Combine
import Foundation
import Network
import UIKit

/// iPad side: finds iPhones in camera mode on the local network, connects with the pairing code, and delivers the iPhone's
/// hand frames and preview picture, with timestamps converted onto the iPad's clock.
final class RemoteCameraLink: NSObject, ObservableObject, @unchecked Sendable {
    struct NearbyPhone: Identifiable, Equatable {
        let id: String
        let name: String
        fileprivate let endpoint: NWEndpoint

        static func == (lhs: NearbyPhone, rhs: NearbyPhone) -> Bool { lhs.id == rhs.id }
    }

    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var nearby: [NearbyPhone] = []
    /// Set when a phone needs its pairing code entered (first time, or after the code changed).
    @Published var needsCode: NearbyPhone?
    @Published private(set) var roundTripMs: Double?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var message: String?

    /// Called on a background queue with every frame (already on the iPad clock).
    var onFrame: (@Sendable (HandFrame) -> Void)?
    /// Called on the main queue with each preview picture.
    var onPreview: (@MainActor (UIImage) -> Void)?
    /// Called on the main queue when the connection starts (name) or ends (nil).
    var onConnectionChange: (@MainActor (_ phoneName: String?) -> Void)?

    private let queue = DispatchQueue(label: "pianopals.companion.link", qos: .userInitiated)
    private var browser: NWBrowser?
    private var active: FramedConnection?
    private var activePhone: NearbyPhone?
    private var clock = ClockSync()
    private var pingTimer: DispatchSourceTimer?
    private var pingCounter: UInt32 = 0
    private var frameTimes: [Double] = []
    private var retryWork: DispatchWorkItem?
    private let lastPhoneKey = "companion.lastPhone"

    var lastPhoneName: String? { UserDefaults.standard.string(forKey: lastPhoneKey) }

    func code(for phoneName: String) -> String? {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "debugPairingCode"), CompanionSecurity.isValid(forced) { return forced }
        #endif
        return PairingKeychain.load(account: "ipad-\(phoneName)")
    }

    // MARK: Searching

    func startSearching() {
        guard state == .idle else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        CompanionSecurity.applyDebugInterface(to: parameters)
        let browser = NWBrowser(for: .bonjour(type: CompanionSecurity.bonjourType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            companionLog.info("browse results: \(results.map { String(describing: $0.endpoint) }.joined(separator: ", "), privacy: .public)")
            let phones = results.compactMap { result -> NearbyPhone? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return NearbyPhone(id: name, name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async { self?.update(nearby: phones) }
        }
        browser.stateUpdateHandler = { [weak self] newState in
            if case .failed = newState {
                DispatchQueue.main.async {
                    self?.state = .idle
                    self?.message = "Couldn't look for iPhones. Allow Local Network access for Piano Pals in Settings."
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        state = .searching
        message = nil
    }

    func stopSearching() {
        retryWork?.cancel()
        browser?.cancel()
        browser = nil
        nearby = []
        if state == .searching { state = .idle }
    }

    private func update(nearby phones: [NearbyPhone]) {
        nearby = phones.sorted { $0.name < $1.name }
        guard state == .searching else { return }
        for phone in phones {
            if let stored = code(for: phone.name), phone.name == lastPhoneName || debugAutoConnect {
                connect(to: phone, code: stored)
                return
            }
        }
    }

    private var debugAutoConnect: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugAutoConnect")
        #else
        return false
        #endif
    }

    // MARK: Connecting

    /// Taps on a phone in the list: uses the saved code if there is one, otherwise asks for it.
    func select(_ phone: NearbyPhone) {
        if let stored = code(for: phone.name) { connect(to: phone, code: stored) } else { needsCode = phone }
    }

    func connect(to phone: NearbyPhone, code typed: String) {
        let code = CompanionSecurity.normalize(typed)
        guard CompanionSecurity.isValid(code) else { message = "The code is 8 digits, shown on the iPhone."; return }
        needsCode = nil
        retryWork?.cancel()
        active?.cancel()
        companionLog.info("connecting to \(phone.name, privacy: .public)")
        let connection = NWConnection(to: phone.endpoint, using: CompanionSecurity.parameters(code: code))
        let framed = FramedConnection(connection: connection, queue: queue)
        active = framed
        activePhone = phone
        state = .connecting(phone.name)
        message = nil
        framed.onState = { [weak self, weak framed] newState in
            DispatchQueue.main.async {
                guard let self, let framed, self.active === framed else { return }
                switch newState {
                case .ready:
                    PairingKeychain.save(code, account: "ipad-\(phone.name)")
                    UserDefaults.standard.set(phone.name, forKey: self.lastPhoneKey)
                    self.state = .connected(phone.name)
                    self.message = nil
                    self.beginPings(on: framed)
                    self.notifyConnection(phone.name)
                case .failed, .cancelled:
                    self.connectionEnded(wasConnecting: { if case .connecting = self.state { return true } else { return false } }(), phone: phone)
                case .waiting(let error):
                    // Typically a wrong code (TLS handshake rejected) or the iPhone's sharing was switched off.
                    self.message = "Waiting for \(phone.name)… (\(error.localizedDescription)) Is the code right?"
                default:
                    break
                }
            }
        }
        framed.onMessage = { [weak self] message in self?.receive(message) }
        framed.start()
    }

    func disconnect() {
        retryWork?.cancel()
        active?.send(.bye)
        let connection = active
        active = nil
        stopPings()
        queue.asyncAfter(deadline: .now() + 0.2) { connection?.cancel() }
        UserDefaults.standard.removeObject(forKey: lastPhoneKey)
        roundTripMs = nil
        framesPerSecond = 0
        if case .connected = state { notifyConnection(nil) }
        state = browser == nil ? .idle : .searching
    }

    func forgetPhone(_ phone: NearbyPhone) {
        PairingKeychain.delete(account: "ipad-\(phone.name)")
    }

    private func connectionEnded(wasConnecting: Bool, phone: NearbyPhone) {
        let wasConnected: Bool = { if case .connected = state { return true } else { return false } }()
        active?.cancel()
        active = nil
        stopPings()
        roundTripMs = nil
        framesPerSecond = 0
        if wasConnecting {
            message = "Couldn't connect to \(phone.name). Check the pairing code on the iPhone."
            PairingKeychain.delete(account: "ipad-\(phone.name)")
            needsCode = phone
        }
        state = browser == nil ? .idle : .searching
        if wasConnected {
            notifyConnection(nil)
            // The iPhone may have gone to sleep or moved: try again shortly.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .searching, let phone = self.nearby.first(where: { $0.name == phone.name }),
                      let stored = self.code(for: phone.name) else { return }
                self.connect(to: phone, code: stored)
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func notifyConnection(_ name: String?) {
        let callback = onConnectionChange
        Task { @MainActor in callback?(name) }
    }

    /// Tells the iPhone to turn or flip its picture.
    func sendControl(rotation: Int, flip: Bool) {
        active?.send(.control(rotation: rotation, flip: flip))
    }

    // MARK: Receiving (background queue)

    private func receive(_ message: CompanionMessage) {
        let arrival = HostClock.now
        switch message {
        case .frame(let wire):
            let padTime = clock.padTime(forPhoneTime: wire.t, arrival: arrival)
            onFrame?(wire.handFrame(channel: .overhead, padTime: padTime))
            countFrame(at: arrival)
        case .preview(let jpeg, _, _):
            guard let image = UIImage(data: jpeg) else { return }
            DispatchQueue.main.async { Task { @MainActor in self.onPreview?(image) } }
        case .pong(_, let echoed, let phoneTime):
            clock.record(sentPad: echoed, phoneTime: phoneTime, receivedPad: arrival)
            let rtt = clock.roundTrip.map { $0 * 1000 }
            DispatchQueue.main.async { self.roundTripMs = rtt }
        case .hello, .ping, .control, .bye:
            break
        }
    }

    private var lastFPSPublish = 0.0

    private func countFrame(at time: Double) {
        frameTimes.append(time)
        frameTimes.removeAll { time - $0 > 1 }
        guard time - lastFPSPublish > 0.5 else { return }
        lastFPSPublish = time
        let fps = Double(frameTimes.count)
        DispatchQueue.main.async { self.framesPerSecond = fps }
    }

    // MARK: Clock sync

    private func beginPings(on connection: FramedConnection) {
        stopPings()
        queue.async { self.clock = ClockSync() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var sent = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.pingCounter &+= 1
            sent += 1
            if sent == 12 { timer.schedule(deadline: .now() + 1, repeating: .seconds(1)) }   // 12 quick pings, then once a second
            connection.send(.ping(id: self.pingCounter, sent: HostClock.now))
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPings() {
        pingTimer?.cancel()
        pingTimer = nil
    }
}

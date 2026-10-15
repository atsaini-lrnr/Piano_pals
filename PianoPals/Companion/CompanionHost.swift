import Combine
import Foundation
import Network
import UIKit

/// iPhone side: shows a pairing code, advertises itself on the local network, and streams hand landmarks + a small
/// preview to the paired iPad over an encrypted connection.
final class CompanionHost: NSObject, ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case waiting
        case connected
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var pairingCode: String
    @Published private(set) var note: String?
    @Published private(set) var framesSent = 0

    /// iPad asked the iPhone to turn / flip its picture.
    var onControl: (@Sendable (_ rotation: Int, _ flip: Bool) -> Void)?

    private let queue = DispatchQueue(label: "pianopals.companion.host", qos: .userInitiated)
    private var listener: NWListener?
    private var active: FramedConnection?
    private static let codeAccount = "host-pairing-code"

    override init() {
        var code = PairingKeychain.load(account: Self.codeAccount) ?? ""
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "debugPairingCode"), CompanionSecurity.isValid(forced) { code = forced }
        #endif
        if !CompanionSecurity.isValid(code) {
            code = CompanionSecurity.makeCode()
            PairingKeychain.save(code, account: Self.codeAccount)
        }
        pairingCode = code
        super.init()
    }

    func start() {
        guard state == .stopped else { return }
        do {
            let listener = try NWListener(using: CompanionSecurity.parameters(code: pairingCode))
            listener.service = NWListener.Service(name: UIDevice.current.name, type: CompanionSecurity.bonjourType)
            listener.newConnectionHandler = { [weak self] connection in
                companionLog.info("host: incoming connection from \(String(describing: connection.endpoint), privacy: .public)")
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] newState in
                companionLog.info("host listener state: \(String(describing: newState), privacy: .public)")
                DispatchQueue.main.async {
                    switch newState {
                    case .ready: self?.note = nil
                    case .failed(let error):
                        // The listener dies when the app is backgrounded or the screen locks. Start a fresh one shortly.
                        self?.note = "Sharing stopped (\(error.localizedDescription)); restarting…"
                        self?.restartListener()
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            state = .waiting
        } catch {
            note = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    /// Replaces a dead listener with a new one (the pairing code and any connected iPad are unaffected).
    func restartListener() {
        guard state != .stopped else { return }
        listener?.cancel()
        listener = nil
        let keepConnected = state == .connected
        if !keepConnected { state = .stopped }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.listener == nil else { return }
            let previous = self.state
            self.state = .stopped
            self.start()
            if previous == .connected { self.state = .connected }
        }
    }

    /// Call when the app returns to the foreground.
    func restartIfNeeded() {
        if state == .stopped { start() } else if listener == nil { restartListener() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        active?.cancel()
        active = nil
        candidates.values.forEach { $0.cancel() }
        candidates = [:]
        state = .stopped
    }


    // MARK: Connection

    /// Network connections race over several paths, so several candidates can arrive for one iPad. A candidate only becomes
    /// *the* connection once it sends its first message, and a healthy connection is never replaced by a newcomer.
    private var candidates: [ObjectIdentifier: FramedConnection] = [:]
    private var lastHeard = Date.distantPast
    /// An established connection that has been silent this long (the iPad pings every second) is considered dead.
    private static let silenceLimit: TimeInterval = 5

    private func accept(_ connection: NWConnection) {
        let framed = FramedConnection(connection: connection, queue: queue)
        let key = ObjectIdentifier(framed)
        DispatchQueue.main.async { self.candidates[key] = framed }
        framed.onMessage = { [weak self, weak framed] message in
            guard let self, let framed else { return }
            DispatchQueue.main.async { self.heard(message, from: framed) }
        }
        framed.onState = { [weak self, weak framed] newState in
            DispatchQueue.main.async {
                guard let self, let framed else { return }
                switch newState {
                case .failed, .cancelled:
                    self.candidates[ObjectIdentifier(framed)] = nil
                    if self.active === framed {
                        self.active = nil
                        self.state = .waiting
                    }
                default:
                    break
                }
            }
        }
        framed.start()
    }

    private func heard(_ message: CompanionMessage, from framed: FramedConnection) {
        if active !== framed {
            let healthy = active != nil && Date().timeIntervalSince(lastHeard) < Self.silenceLimit
            if healthy {
                companionLog.info("host: dropping duplicate connection")
                candidates[ObjectIdentifier(framed)] = nil
                framed.cancel()
                return
            }
            active?.cancel()
            active = framed
            candidates[ObjectIdentifier(framed)] = nil
            state = .connected
            framed.send(.hello(name: UIDevice.current.name, platform: "iPhone", version: CompanionConstants.protocolVersion))
            companionLog.info("host: iPad connected")
        }
        lastHeard = Date()
        switch message {
        case .ping(let id, let sent):
            framed.send(.pong(id: id, echoed: sent, phoneTime: HostClock.now))
        case .control(let rotation, let flip):
            onControl?(rotation, flip)
        case .bye:
            framed.cancel()
        default:
            break
        }
    }

    // MARK: Sending (any thread)

    func send(frame: HandFrame) {
        guard let connection = active, state == .connected else { return }
        connection.send(.frame(WireFrame(frame)), droppable: true)
        DispatchQueue.main.async { self.framesSent += 1 }
    }

    func send(previewJPEG: Data, width: Int, height: Int) {
        guard let connection = active, state == .connected, previewJPEG.count < 200_000 else { return }
        connection.send(.preview(jpeg: previewJPEG, w: width, h: height), droppable: true)
    }
}

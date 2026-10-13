import AVFoundation
import Combine
import Foundation

/// Owns the two camera channels, discovers cameras (including a nearby iPhone via Continuity Camera or any
/// external UVC camera), and keeps the channel ↔ device assignment consistent.
@MainActor
final class CameraHub: ObservableObject {
    @Published private(set) var availableDevices: [CameraDeviceInfo] = []
    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var layout: CameraLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Keys.layout) }
    }
    /// In picture-in-picture layout, which channel is shown large.
    @Published var pipLargeChannel: CameraChannelID = .primary
    @Published var trackingPreference: TrackingPreference {
        didSet { UserDefaults.standard.set(trackingPreference.rawValue, forKey: Keys.tracking) }
    }
    @Published var preferredFPS: Double {
        didSet { UserDefaults.standard.set(preferredFPS, forKey: Keys.fps) }
    }
    @Published private(set) var notice: String?

    let primary = CameraChannel(id: .primary)
    let overhead = CameraChannel(id: .overhead)
    /// Link to a nearby iPhone running Piano Pals in camera mode (iPadOS doesn't offer an iPhone as a system camera).
    let companion = RemoteCameraLink()

    private enum Keys {
        static let primaryID = "camera.primaryID"
        static let overheadID = "camera.overheadID"
        static let layout = "camera.layout"
        static let tracking = "camera.tracking"
        static let fps = "camera.fps"
        static let primaryRotation = "camera.primaryRotation"
        static let overheadRotation = "camera.overheadRotation"
        static let primaryFlip = "camera.primaryFlip"
        static let overheadFlip = "camera.overheadFlip"
    }

    private let discovery: AVCaptureDevice.DiscoverySession
    private var observers: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false
    /// Explicit "no camera for this channel" choices, so auto-assignment doesn't undo them.
    private var userClearedChannels: Set<CameraChannelID> = []

    static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera, .continuityCamera, .external
    ]

    init() {
        let defaults = UserDefaults.standard
        layout = CameraLayout(rawValue: defaults.string(forKey: Keys.layout) ?? "") ?? .grid
        trackingPreference = TrackingPreference(rawValue: defaults.string(forKey: Keys.tracking) ?? "") ?? .automatic
        let storedFPS = defaults.double(forKey: Keys.fps)
        preferredFPS = storedFPS == 0 ? 60 : storedFPS
        discovery = AVCaptureDevice.DiscoverySession(deviceTypes: CameraHub.deviceTypes, mediaType: .video, position: .unspecified)

        primary.manualRotation = defaults.integer(forKey: Keys.primaryRotation)
        overhead.manualRotation = defaults.integer(forKey: Keys.overheadRotation)
        primary.flipHorizontally = defaults.bool(forKey: Keys.primaryFlip)
        overhead.flipHorizontally = defaults.bool(forKey: Keys.overheadFlip)

        // Persist orientation tweaks.
        primary.$manualRotation.dropFirst().sink { defaults.set($0, forKey: Keys.primaryRotation) }.store(in: &cancellables)
        overhead.$manualRotation.dropFirst().sink { defaults.set($0, forKey: Keys.overheadRotation) }.store(in: &cancellables)
        primary.$flipHorizontally.dropFirst().sink { defaults.set($0, forKey: Keys.primaryFlip) }.store(in: &cancellables)
        overhead.$flipHorizontally.dropFirst().sink { defaults.set($0, forKey: Keys.overheadFlip) }.store(in: &cancellables)
        // The iPhone companion feeds the overhead channel.
        let overheadChannel = overhead
        companion.onFrame = { frame in overheadChannel.publishRemote(frame: frame) }
        companion.onPreview = { image in overheadChannel.setRemotePreview(image) }
        companion.onConnectionChange = { [weak self] name in
            guard let self else { return }
            if let name {
                self.overhead.attachRemote(name: name)
                self.notice = "Using \(name) as the overhead camera."
            } else if self.overhead.isRemote {
                self.overhead.detachRemote()
                self.notice = "The iPhone camera disconnected."
            }
        }
        // Turn / flip changes on the iPad are passed on to the iPhone.
        overhead.$manualRotation.dropFirst().sink { [weak self] _ in self?.sendCompanionOrientation() }.store(in: &cancellables)
        overhead.$flipHorizontally.dropFirst().sink { [weak self] _ in self?.sendCompanionOrientation() }.store(in: &cancellables)
        companion.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // Re-publish channel changes so views observing only the hub update.
        primary.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        overhead.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    func channel(_ id: CameraChannelID) -> CameraChannel { id == .primary ? primary : overhead }

    private func sendCompanionOrientation() {
        guard overhead.isRemote else { return }
        companion.sendControl(rotation: overhead.manualRotation, flip: overhead.flipHorizontally)
    }

    /// Reconnects to the iPhone used last time, if there was one (called once the app is up).
    func resumeCompanionIfKnown() {
        var shouldSearch = companion.lastPhoneName != nil
        #if DEBUG
        shouldSearch = shouldSearch || UserDefaults.standard.bool(forKey: "debugAutoConnect")
        #endif
        if shouldSearch { companion.startSearching() }
    }

    /// The channel whose hand tracking drives finger checking.
    var trackingChannel: CameraChannelID {
        switch trackingPreference {
        case .primary: return .primary
        case .overhead: return .overhead
        case .automatic: return overhead.state == .running ? .overhead : .primary
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        observeDevices()

        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard authorization == .authorized else {
            primary.setUnavailable(.denied)
            overhead.setUnavailable(.denied)
            return
        }
        refreshCatalog()
        assignInitialDevices()
    }

    func stop() {
        isStarted = false
        primary.stop()
        overhead.stop()
        observers.removeAll()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    /// Pause capture when the app leaves the foreground; resume on return.
    func setActive(_ active: Bool) {
        if active {
            // The grown-up may have just switched the camera on in Settings.
            let current = AVCaptureDevice.authorizationStatus(for: .video)
            if current != authorization {
                authorization = current
                if current == .authorized {
                    refreshCatalog()
                    assignInitialDevices()
                    return
                }
            }
        }
        guard authorization == .authorized else { return }
        if active {
            for id in CameraChannelID.allCases where channel(id).state == .idle {
                if let info = assignedDeviceInfo(for: id) { startChannel(id, with: info) }
            }
        } else {
            primary.stop()
            overhead.stop()
        }
    }

    // MARK: Discovery

    private func observeDevices() {
        observers = [
            discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.devicesChanged() }
            }
        ]
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            }
        ]
    }

    func refreshCatalog() {
        #if DEBUG
        for device in discovery.devices {
            CameraChannel.log.info("catalog: \(device.localizedName, privacy: .public) | \(device.deviceType.rawValue, privacy: .public) | position \(device.position.rawValue) | \(device.uniqueID, privacy: .public)")
        }
        #endif
        var seen = Set<String>()
        availableDevices = discovery.devices
            .filter { seen.insert($0.uniqueID).inserted }
            .map(CameraDeviceInfo.init(device:))
            .sorted { lhs, rhs in
                if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
                return lhs.name < rhs.name
            }
    }

    private func devicesChanged() {
        refreshCatalog()
        guard authorization == .authorized else { return }

        for id in CameraChannelID.allCases {
            let ch = channel(id)
            if let current = ch.deviceInfo, !availableDevices.contains(current) {
                ch.stop()
                notice = "The \(id.displayName.lowercased()) camera was disconnected."
            }
        }
        // A nearby iPhone appearing becomes the overhead camera automatically.
        if overhead.deviceInfo == nil, !userClearedChannels.contains(.overhead),
           let remote = availableDevices.first(where: \.isRemote), remote.id != primary.deviceInfo?.id {
            startChannel(.overhead, with: remote)
            notice = "Using \(remote.name) as the overhead camera."
        }
        if primary.deviceInfo == nil, !userClearedChannels.contains(.primary), let builtIn = defaultPrimary() {
            startChannel(.primary, with: builtIn)
        }
    }

    // MARK: Assignment

    private func defaultPrimary() -> CameraDeviceInfo? {
        #if DEBUG
        if let wanted = UserDefaults.standard.string(forKey: "debugCamera"),
           let match = availableDevices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) { return match }
        #endif
        return availableDevices.first { $0.kind == .front } ?? availableDevices.first { $0.isBuiltIn }
    }

    private func assignInitialDevices() {
        let defaults = UserDefaults.standard
        var storedPrimary = defaults.string(forKey: Keys.primaryID).flatMap { id in availableDevices.first { $0.id == id } }
        #if DEBUG
        // `-debugCamera <name>` wins over any saved choice, for testing individual cameras.
        if let wanted = defaults.string(forKey: "debugCamera"), let match = availableDevices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) { storedPrimary = match }
        #endif
        let storedOverhead = defaults.string(forKey: Keys.overheadID).flatMap { id in availableDevices.first { $0.id == id } }

        if let info = storedPrimary ?? defaultPrimary() { startChannel(.primary, with: info) } else { primary.setUnavailable(.noCamera) }
        if let info = storedOverhead ?? availableDevices.first(where: { $0.isRemote && $0.id != primary.deviceInfo?.id }) {
            startChannel(.overhead, with: info)
        } else {
            overhead.setUnavailable(.noCamera)
        }
    }

    private func assignedDeviceInfo(for id: CameraChannelID) -> CameraDeviceInfo? {
        let key = id == .primary ? Keys.primaryID : Keys.overheadID
        if let stored = UserDefaults.standard.string(forKey: key), let info = availableDevices.first(where: { $0.id == stored }) {
            return info
        }
        return id == .primary ? defaultPrimary() : availableDevices.first(where: { $0.isRemote })
    }

    /// True when `info` may be given to `channel` (a built-in camera can only serve one channel at a time).
    func canAssign(_ info: CameraDeviceInfo, to channelID: CameraChannelID) -> Bool {
        let other = channel(channelID == .primary ? .overhead : .primary)
        guard let otherInfo = other.deviceInfo else { return true }
        if otherInfo.id == info.id { return false }
        if info.isBuiltIn && otherInfo.isBuiltIn { return false }
        return true
    }

    func assign(_ info: CameraDeviceInfo?, to channelID: CameraChannelID) {
        let key = channelID == .primary ? Keys.primaryID : Keys.overheadID
        guard let info else {
            userClearedChannels.insert(channelID)
            UserDefaults.standard.removeObject(forKey: key)
            channel(channelID).stop()
            return
        }
        guard canAssign(info, to: channelID) else {
            notice = "That camera is already in use by the other view."
            return
        }
        userClearedChannels.remove(channelID)
        UserDefaults.standard.set(info.id, forKey: key)
        startChannel(channelID, with: info)
    }

    private func startChannel(_ id: CameraChannelID, with info: CameraDeviceInfo) {
        guard authorization == .authorized else { return }
        if id == .overhead, overhead.isRemote { return }
        let ch = channel(id)
        guard let device = AVCaptureDevice(uniqueID: info.id) else {
            ch.setUnavailable(.noCamera)
            return
        }
        ch.stop()
        ch.wantsFaceExpression = (id == .primary && info.kind == .front)
        ch.start(device: device, preferredFPS: preferredFPS)
    }

    /// Restarts both channels (used after changing the frame-rate preference).
    func restartChannels() {
        for id in CameraChannelID.allCases {
            if let info = channel(id).deviceInfo { startChannel(id, with: info) }
        }
    }

    func dismissNotice() { notice = nil }
}

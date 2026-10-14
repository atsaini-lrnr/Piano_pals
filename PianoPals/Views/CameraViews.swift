import SwiftUI

/// One camera's live picture with the hand overlay on top (or a friendly placeholder when there's no camera).
struct CameraTile: View {
    @ObservedObject var channel: CameraChannel
    let title: String
    var highlight: Finger?
    var isTracking = false
    var demoBackdrop = false
    var coaching: CoachingContext?
    var placeholderButton: (title: String, action: () -> Void)?

    var body: some View {
        ZStack {
            Color.black
            if channel.isRemote {
                RemotePreviewImage(image: channel.remotePreview)
            } else {
                switch channel.state {
                case .running, .starting, .interrupted:
                    CameraPreviewView(channel: channel)
                default:
                    placeholder
                }
            }
            HandOverlayView(frame: channel.latestFrame, highlight: highlight)
            if let coaching, channel.state == .running || demoBackdrop {
                CoachingOverlayView(frame: channel.latestFrame, context: coaching, imageSize: channel.latestFrame?.imageSize ?? channel.videoSize)
            }

            VStack {
                HStack {
                    Label(title, systemImage: channel.deviceInfo?.symbolName ?? "video")
                        .font(.kid(18, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.55)))
                    Spacer()
                    if isTracking, channel.state == .running || demoBackdrop {
                        Label("Watching hands", systemImage: "eye.fill")
                            .font(.kid(15, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Palette.success.opacity(0.9)))
                    }
                }
                Spacer()
            }
            .padding(10)

            if channel.state == .interrupted {
                Text("Camera paused…").font(.kid(24)).foregroundStyle(.white)
                    .padding(16).background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.6)))
            }
        }
        .aspectRatio(channel.state == .running ? max(channel.videoSize.width / max(channel.videoSize.height, 1), 0.5) : 16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white, lineWidth: 4))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            if demoBackdrop {
                LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.45), Color(red: 0.16, green: 0.14, blue: 0.26)], startPoint: .top, endPoint: .bottom)
                // A stripe of "keys" for demo-hand context.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(0..<16, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.85))
                        }
                    }
                    .frame(height: geo.size.height * 0.34)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.80)
                }
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 34, weight: .bold)).padding(.top, 30)
                    Text(message).font(.kid(20, weight: .bold)).multilineTextAlignment(.center)
                    if let placeholderButton {
                        Button(action: placeholderButton.action) {
                            Text(placeholderButton.title).font(.kid(20))
                                .padding(.horizontal, 22).padding(.vertical, 12)
                                .background(Capsule().fill(Palette.blueButton))
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(20)
            }
        }
    }

    private var icon: String {
        switch channel.state {
        case .denied: return "video.slash"
        case .failed: return "exclamationmark.triangle"
        default: return channel.id == .overhead ? "iphone.gen3" : "video"
        }
    }

    private var message: String {
        switch channel.state {
        case .denied: return "Camera is off. A grown-up can turn it on in Settings."
        case .failed: return "The camera isn't working right now. Ask a grown-up to check it."
        case .noCamera: return channel.id == .overhead ? "No overhead camera yet" : "No camera found"
        default: return "Getting the camera ready…"
        }
    }
}

/// The picture sent by the iPhone, filling the tile.
private struct RemotePreviewImage: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Waiting for the iPhone's picture…").font(.kid(18, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}

/// Shows both camera angles either side by side (stacked in the side column) or as picture-in-picture.
struct CameraPanel: View {
    @ObservedObject var hub: CameraHub
    var highlight: Finger?
    var demoHands: Bool
    var onChoose: () -> Void

    var body: some View {
        switch hub.layout {
        case .grid:
            VStack(spacing: 14) {
                tile(.primary)
                tile(.overhead)
            }
        case .pip:
            let large = hub.pipLargeChannel
            let small: CameraChannelID = large == .primary ? .overhead : .primary
            ZStack(alignment: .bottomTrailing) {
                tile(large)
                tile(small)
                    .frame(width: 190)
                    .padding(10)
                    .onTapGesture { withAnimation(.spring) { hub.pipLargeChannel = small } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Swap the big and small camera")
            }
        }
    }

    private func tile(_ id: CameraChannelID) -> some View {
        CameraTile(channel: hub.channel(id),
                   title: id == .primary ? "Side view" : "Top view",
                   highlight: highlight,
                   isTracking: hub.trackingChannel == id,
                   demoBackdrop: demoHands && id == .primary && hub.channel(id).state != .running,
                   placeholderButton: id == .overhead && hub.channel(id).state != .running && hub.authorization == .authorized
                       ? ("Use my iPhone", onChoose) : nil)
    }
}

/// The camera section across the top of the lesson: both views side by side, as large as the height allows.
struct CameraBand: View {
    @ObservedObject var hub: CameraHub
    var highlight: Finger?
    var demoHands: Bool
    var coaching: (CameraChannelID) -> CoachingContext?
    var onChoose: () -> Void

    var body: some View {
        switch hub.layout {
        case .grid:
            let overheadLive = hub.overhead.state == .running
            GeometryReader { geo in
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    tile(.primary)
                    tile(.overhead).frame(width: overheadLive ? nil : geo.size.width * 0.26)
                    Spacer(minLength: 0)
                }
            }
        case .pip:
            let large = hub.pipLargeChannel
            let small: CameraChannelID = large == .primary ? .overhead : .primary
            ZStack(alignment: .bottomTrailing) {
                tile(large)
                tile(small).frame(width: 220).padding(10)
                    .onTapGesture { withAnimation(.spring) { hub.pipLargeChannel = small } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Swap the big and small camera")
            }
        }
    }

    private func tile(_ id: CameraChannelID) -> some View {
        CameraTile(channel: hub.channel(id),
                   title: id == .primary ? "Side view" : "Top view",
                   highlight: highlight,
                   isTracking: hub.trackingChannel == id,
                   demoBackdrop: demoHands && id == .primary && hub.channel(id).state != .running,
                   coaching: coaching(id),
                   placeholderButton: id == .overhead && hub.channel(id).state != .running && hub.authorization == .authorized
                       ? ("Use my iPhone", onChoose) : nil)
    }
}

/// Custom camera chooser. iPadOS has no system Continuity Camera picker view (that class is tvOS-only), so a nearby iPhone
/// shows up here automatically once it's available, and the grown-up taps to give it a job.
struct CameraPickerSheet: View {
    @ObservedObject var hub: CameraHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CameraChannelID.allCases) { channel in
                        HStack {
                            Image(systemName: hub.channel(channel).deviceInfo?.symbolName ?? "video.slash")
                                .frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(channel.displayName).font(.headline)
                                Text(hub.channel(channel).deviceInfo?.name ?? "No camera").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hub.channel(channel).deviceInfo != nil {
                                Button("Turn off") { hub.assign(nil, to: channel) }.buttonStyle(.bordered)
                            }
                        }
                    }
                } header: { Text("Now showing") }

                Section {
                    if hub.availableDevices.isEmpty {
                        Text("No cameras found yet.").foregroundStyle(.secondary)
                    }
                    ForEach(hub.availableDevices) { device in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: device.symbolName).frame(width: 32)
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.headline)
                                    Text(device.kindDescription).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                ForEach(CameraChannelID.allCases) { channel in
                                    let inUse = hub.channel(channel).deviceInfo?.id == device.id
                                    Button(inUse ? "✓ \(channel.displayName)" : "Use for \(channel.displayName.lowercased())") {
                                        hub.assign(device, to: channel)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(inUse || !hub.canAssign(device, to: channel))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("Available cameras")
                        Spacer()
                        Button("Refresh") { hub.refreshCatalog() }.font(.subheadline)
                    }
                } footer: {
                    Text("Only one of the iPad's own cameras can run at a time, so pair it with your iPhone for the second view.")
                }

                Section {
                    CompanionSection(link: hub.companion, overhead: hub.overhead)
                } header: { Text("Use your iPhone as the overhead camera") } footer: {
                    Text("iPadOS doesn't offer an iPhone as a normal camera, so Piano Pals does it itself: the iPhone watches the keys, finds the hands, and sends just the hand positions to the iPad over a private local connection. No internet, no recording.")
                }

                if let notice = hub.notice {
                    Section { Text(notice).foregroundStyle(.orange) }
                }
            }
            .modifier(PairingCodePrompt(link: hub.companion))
            .navigationTitle("Choose cameras")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                hub.refreshCatalog()
                hub.companion.startSearching()
            }
            .onDisappear { hub.companion.stopSearching() }
        }
    }
}

/// Step-by-step connection to a nearby iPhone in camera mode.
private struct CompanionSection: View {
    @ObservedObject var link: RemoteCameraLink
    @ObservedObject var overhead: CameraChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Open Piano Pals on your iPhone. It becomes a camera automatically.", systemImage: "1.circle")
            Label("Prop the iPhone above the keys, pointing down. Keep both on the same Wi-Fi (or Bluetooth on).", systemImage: "2.circle")
            Label("Pick your iPhone below and type the 8-digit pairing code shown on it (only needed once).", systemImage: "3.circle")
        }
        .font(.callout)

        switch link.state {
        case .connected(let name):
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("Connected to \(name)").font(.headline)
                    Text(String(format: "%.0f hand updates/s%@", link.framesPerSecond,
                                link.roundTripMs.map { String(format: " · %.0f ms to the iPhone", $0) } ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Disconnect") { link.disconnect() }.buttonStyle(.bordered)
            }
        case .connecting(let name):
            HStack { ProgressView(); Text("Connecting to \(name)…") }
        case .idle, .searching:
            if link.nearby.isEmpty {
                HStack { ProgressView(); Text("Looking for iPhones in camera mode…").foregroundStyle(.secondary) }
            }
            ForEach(link.nearby) { phone in
                Button { link.select(phone) } label: {
                    HStack {
                        Image(systemName: "iphone.gen3")
                        Text(phone.name)
                        Spacer()
                        Text("Connect").foregroundStyle(.tint)
                    }
                }
            }
            if link.state == .idle {
                Button("Look again") { link.startSearching() }.buttonStyle(.bordered)
            }
        }
        if let message = link.message { Text(message).font(.footnote).foregroundStyle(.orange) }
    }
}

/// Asks for the pairing code shown on the iPhone.
private struct PairingCodePrompt: ViewModifier {
    @ObservedObject var link: RemoteCameraLink
    @State private var typed = ""

    func body(content: Content) -> some View {
        content.alert("Pairing code", isPresented: Binding(get: { link.needsCode != nil }, set: { if !$0 { link.needsCode = nil } }),
                      presenting: link.needsCode) { phone in
            TextField("8-digit code", text: $typed).keyboardType(.numberPad)
            Button("Connect") {
                link.connect(to: phone, code: typed)
                typed = ""
            }
            Button("Cancel", role: .cancel) { typed = "" }
        } message: { phone in
            Text("Type the code shown on “\(phone.name)”.")
        }
    }
}

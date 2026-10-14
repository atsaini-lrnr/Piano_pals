import SwiftUI

/// What an iPhone shows: a simple camera screen for the iPad to borrow.
struct CompanionRootView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CompanionContent(model: model, channel: model.channel, host: model.host)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task { await model.start() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.host.restartIfNeeded() } }
    }
}

private struct CompanionContent: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var channel: CameraChannel
    @ObservedObject var host: CompanionHost

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.permissionDenied {
                message(icon: "video.slash", text: "Camera access is off. Turn it on in Settings ▸ Piano Pals.")
            } else if model.noCamera && !UserDefaults.standard.bool(forKey: "demoHands") {
                message(icon: "video", text: "No camera found on this device.")
            } else {
                // Aspect-FIT so the whole picture is visible: exactly what the iPad receives and what hand tracking sees.
                CameraPreviewView(channel: channel, gravity: .resizeAspect).ignoresSafeArea()
                HandOverlayView(frame: channel.latestFrame, highlight: nil, fit: true)
            }

            // Controls live on the right edge and the status on the top-left, so the middle (where the hands are) stays clear.
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        statusChip
                        if host.state != .connected { pairingPanel }
                    }
                    Spacer()
                    VStack(spacing: 12) {
                        control("camera.rotate.fill", "Switch camera") { model.switchCamera() }
                        control("rotate.right.fill", "Turn picture") { channel.manualRotation = (channel.manualRotation + 90) % 360 }
                        control("arrow.left.and.right.righttriangle.left.righttriangle.right.fill", "Flip") { channel.flipHorizontally.toggle() }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
            }
        }
    }

    private var pairingPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Pairing code").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.75))
            Text(CompanionSecurity.display(host.pairingCode))
                .font(.system(size: 26, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
            Text("iPad: Grown-ups ▸ Choose cameras ▸ pick this iPhone ▸ type the code.")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if let note = host.note { Text(note).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55)))
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            switch host.state {
            case .stopped: return ("Not sharing", .gray)
            case .waiting: return ("Waiting for the iPad…", .orange)
            case .connected: return ("Connected to the iPad", .green)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.6)))
    }

    private func control(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold)).frame(width: 56, height: 56)
                .background(Circle().fill(.white.opacity(0.22)))
        }
        .accessibilityLabel(label)
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44))
            Text(text).font(.system(size: 20, weight: .bold, design: .rounded)).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

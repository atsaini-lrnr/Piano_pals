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
                CameraPreviewView(channel: channel).ignoresSafeArea()
                HandOverlayView(frame: channel.latestFrame, highlight: nil)
            }

            VStack {
                HStack(spacing: 10) {
                    statusChip
                    Spacer()
                    Text("Piano Pals camera").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
                HStack(spacing: 14) {
                    control("camera.rotate.fill", "Switch camera") { model.switchCamera() }
                    control("rotate.right.fill", "Turn picture") { channel.manualRotation = (channel.manualRotation + 90) % 360 }
                    control("arrow.left.and.right.righttriangle.left.righttriangle.right.fill", "Flip") { channel.flipHorizontally.toggle() }
                }
                .padding(.bottom, 14)
                if host.state != .connected {
                    VStack(spacing: 4) {
                        Text("Pairing code").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                        Text(CompanionSecurity.display(host.pairingCode))
                            .font(.system(size: 34, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                        Text("On the iPad: Grown-ups ▸ Choose cameras ▸ pick this iPhone ▸ type the code. Point this iPhone down at the keys.")
                            .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                        if let note = host.note { Text(note).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 24) }
                    }
                    .padding(.bottom, 10)
                }
            }

        }
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

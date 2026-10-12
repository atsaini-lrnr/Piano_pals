import SwiftUI

struct CalibrationView: View {
    let app: AppModel
    @StateObject private var flow: CalibrationFlow

    init(app: AppModel) {
        self.app = app
        _flow = StateObject(wrappedValue: CalibrationFlow(firstNote: app.keyboardRange.lowerBound, lastNote: app.keyboardRange.upperBound))
    }

    var body: some View {
        CalibrationContent(app: app, flow: flow, channel: app.cameras.channel(app.cameras.trackingChannel),
                           avatar: app.avatar, settings: app.settings, confetti: app.confetti)
    }
}

private struct CalibrationContent: View {
    let app: AppModel
    @ObservedObject var flow: CalibrationFlow
    @ObservedObject var channel: CameraChannel
    @ObservedObject var avatar: AvatarModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var confetti: ConfettiModel

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    BigIconButton(systemImage: "house.fill", label: "Home", color: Palette.pink) { app.screen = .home }
                    AvatarView(mood: avatar.mood, childSmile: avatar.childSmile).frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(instruction).font(.kid(44)).foregroundStyle(Palette.ink).minimumScaleFactor(0.6).lineLimit(2)
                        Text(subtitle).font(.kid(24, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.7))
                    }
                    Spacer()
                    stepDots
                }

                ZStack {
                    CameraTile(channel: channel, title: app.cameras.trackingChannel == .overhead ? "Top view" : "Side view",
                               isTracking: true,
                               demoBackdrop: settings.demoHands && channel.state != .running)
                    TemplateOverlay(step: flow.currentStep, aligned: flow.isAligned, handSeen: flow.handSeen, progress: flow.progress)
                    if let outcome = flow.outcome { outcomeCard(outcome) }
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 20) {
                    if flow.outcome == nil {
                        Button("Skip this part (grown-ups)") { flow.skipCurrentStep() }
                            .font(.kid(20, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.7))
                            .frame(minHeight: 60)
                    }
                }
            }
            .padding(28)
            ConfettiView(model: confetti).ignoresSafeArea()
        }
        .onAppear { announceStep() }
        .onChange(of: flow.currentIndex) { _, _ in announceStep() }
        .onChange(of: flow.outcome) { _, outcome in handle(outcome) }
        .onReceive(channel.$latestFrame.compactMap { $0 }) { frame in
            if channel.state == .running { flow.ingest(frame) }
        }
        .task(id: settings.demoHands) { await runDemo() }
        .onReceive(flow.stepCompleted) { _ in
            confetti.fire(.burst, at: CGPoint(x: 0.5, y: 0.5), accent: Palette.success)
            avatar.set(.cheering, for: 1.5)
        }
    }

    private var instruction: String {
        if flow.outcome != nil { return "All done!" }
        guard let step = flow.currentStep else { return "Let's look at your hands!" }
        return step.side == .right ? "Right hand on the print!" : "Now your left hand!"
    }

    private var subtitle: String {
        if let outcome = flow.outcome, case .failed(let message) = outcome { return message }
        if flow.outcome != nil { return "The piano can see your hands." }
        if !flow.handSeen { return "Hold your hand over the keys so the camera can see it." }
        return flow.isAligned ? "Hold still… you're doing it!" : "Line up your fingers with the colourful dots."
    }

    private var stepDots: some View {
        HStack(spacing: 12) {
            ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, step in
                let done = index < flow.currentIndex || { if case .success = flow.outcome { return true } else { return false } }()
                VStack(spacing: 2) {
                    Image(systemName: done ? "checkmark.circle.fill" : "hand.raised.fill")
                        .font(.system(size: 44))
                        .scaleEffect(x: step.side == .left ? -1 : 1)
                    Text(step.side == .right ? "Right" : "Left").font(.kid(16, weight: .bold))
                }
                .foregroundStyle(done ? Palette.success : Palette.ink.opacity(index == flow.currentIndex ? 1 : 0.35))
            }
        }
    }

    @ViewBuilder
    private func outcomeCard(_ outcome: CalibrationFlow.Outcome) -> some View {
        VStack(spacing: 20) {
            switch outcome {
            case .success:
                StarRow(filled: 3, size: 90)
                BigButton(title: "Let's play!", systemImage: "play.fill", color: Palette.play) { app.screen = .songs }
            case .failed:
                BigButton(title: "Try again", systemImage: "arrow.counterclockwise", color: Palette.blueButton) { flow.restart() }
                BigButton(title: "Play anyway", systemImage: "play.fill", color: Palette.play) { app.screen = .songs }
            }
        }
        .frame(width: 520)
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(.white.opacity(0.96)))
        .shadow(radius: 14)
    }

    private func announceStep() {
        guard flow.outcome == nil, let step = flow.currentStep else { return }
        app.narrator.say(step.spokenInstruction)
    }

    private func handle(_ outcome: CalibrationFlow.Outcome?) {
        guard let outcome else { return }
        switch outcome {
        case .success(let region):
            app.saveCalibration(region, for: app.cameras.trackingChannel)
            confetti.fire(.finale, at: CGPoint(x: 0.5, y: 0.3), accent: Palette.sunny)
            avatar.set(.cheering, for: 3)
            app.narrator.say("All done! The piano can see your hands.")
        case .failed(let message):
            avatar.set(.encouraging, for: 3)
            app.narrator.say("Let's try again!")
            _ = message
        }
    }

    /// With no camera (Simulator) and Demo hands on, a pretend hand lines itself up with each print.
    private func runDemo() async {
        guard settings.demoHands, channel.state != .running else { return }
        try? await Task.sleep(for: .seconds(1.2))
        while !Task.isCancelled {
            if flow.outcome == nil, let step = flow.currentStep {
                let frame = DemoHandSource.templateFrame(channel: channel.id, template: step.template, time: HostClock.now)
                channel.publishSynthetic(frame: frame)
                flow.ingest(frame)
            }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }
}

/// The big hand-print outline. It turns from white to yellow (hand seen) to green (lined up) and fills a ring as the child holds still.
private struct TemplateOverlay: View {
    let step: CalibrationStep?
    let aligned: Bool
    let handSeen: Bool
    let progress: Double

    var body: some View {
        Canvas { canvas, size in
            guard let step else { return }
            let template = step.template
            func point(_ joint: JointID) -> CGPoint {
                let p = template.target(for: joint) ?? .zero
                return CGPoint(x: p.x * size.width, y: p.y * size.height)
            }
            let outline: Color = aligned ? Palette.success : (handSeen ? Palette.hint : .white)
            let fingerWidth = template.placement.width * size.width * 0.085

            func chain(_ joints: [JointID]) -> Path {
                var path = Path()
                path.move(to: point(joints[0]))
                for joint in joints.dropFirst() { path.addLine(to: point(joint)) }
                return path
            }
            var shapes: [Path] = Finger.allCases.map { finger -> Path in
                switch finger {
                case .thumb: return chain([.thumbCMC, .thumbMP, .thumbIP, .thumbTip])
                case .index: return chain([.indexMCP, .indexPIP, .indexDIP, .indexTip])
                case .middle: return chain([.middleMCP, .middlePIP, .middleDIP, .middleTip])
                case .ring: return chain([.ringMCP, .ringPIP, .ringDIP, .ringTip])
                case .pinky: return chain([.littleMCP, .littlePIP, .littleDIP, .littleTip])
                }
            }
            var palm = chain([.wrist, .thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP])
            palm.closeSubpath()
            shapes.append(palm)

            let round = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
            for shape in shapes { canvas.stroke(shape, with: .color(outline), style: round(fingerWidth + 12)) }
            canvas.stroke(palm, with: .color(outline), style: round(fingerWidth * 0.6 + 12))
            for shape in shapes { canvas.stroke(shape, with: .color(.white.opacity(0.35)), style: round(fingerWidth)) }
            canvas.fill(palm, with: .color(.white.opacity(0.35)))
            canvas.stroke(palm, with: .color(.white.opacity(0.35)), style: round(fingerWidth * 0.6))

            // Coloured finger dots to match on-screen guidance.
            for finger in Finger.allCases {
                let p = point(JointID.tip(of: finger))
                let r = fingerWidth * 0.62
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                canvas.fill(finger.glyph.path(in: rect), with: .color(finger.color))
                canvas.draw(Text("\(finger.number)").font(.kid(r * 0.9)).foregroundStyle(.white), at: p)
            }

            // Progress ring around the palm.
            let centre = CGPoint(x: point(.middleMCP).x, y: (point(.middleMCP).y + point(.wrist).y) / 2)
            let ringRadius = fingerWidth * 1.6
            let ring = Path(ellipseIn: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            canvas.stroke(ring, with: .color(.white.opacity(0.5)), lineWidth: 12)
            canvas.stroke(ring.trimmedPath(from: 0, to: progress), with: .color(Palette.success), style: round(12))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.15), value: aligned)
    }
}

import XCTest
@testable import PianoPals

final class VisionGeometryTests: XCTestCase {
    // MARK: Hand conversion

    func testVisionCoordinatesAreFlippedToTopLeftOrigin() {
        let hand = HandPoseProcessor.makeHand(
            id: 0, rawJoints: [.indexTip: (CGPoint(x: 0.25, y: 0.8), 0.9)], chirality: .right, mirrored: false, minimumConfidence: 0.3)
        XCTAssertEqual(hand?.tip(of: .index)?.point.x ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(hand?.tip(of: .index)?.point.y ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(hand?.side, .right)
    }

    func testMirroredVideoSwapsHandedness() {
        let joints: [JointID: (location: CGPoint, confidence: Float)] = [.wrist: (CGPoint(x: 0.5, y: 0.5), 1)]
        XCTAssertEqual(HandPoseProcessor.makeHand(id: 0, rawJoints: joints, chirality: .right, mirrored: true, minimumConfidence: 0.3)?.side, .left)
        XCTAssertEqual(HandPoseProcessor.makeHand(id: 0, rawJoints: joints, chirality: .left, mirrored: true, minimumConfidence: 0.3)?.side, .right)
        XCTAssertNil(HandPoseProcessor.makeHand(id: 0, rawJoints: joints, chirality: nil, mirrored: true, minimumConfidence: 0.3)?.side)
    }

    func testLowConfidenceJointsAreDropped() {
        let joints: [JointID: (location: CGPoint, confidence: Float)] = [
            .wrist: (CGPoint(x: 0.5, y: 0.5), 0.9), .indexTip: (CGPoint(x: 0.5, y: 0.5), 0.1)]
        let hand = HandPoseProcessor.makeHand(id: 0, rawJoints: joints, chirality: nil, mirrored: false, minimumConfidence: 0.3)
        XCTAssertNotNil(hand?.joint(.wrist))
        XCTAssertNil(hand?.joint(.indexTip))
        XCTAssertNil(HandPoseProcessor.makeHand(id: 0, rawJoints: [.wrist: (CGPoint(x: 0, y: 0), 0.1)], chirality: nil, mirrored: false, minimumConfidence: 0.3))
    }

    func testAll21JointsAreDefinedAndMapped() {
        XCTAssertEqual(JointID.allCases.count, 21)
        XCTAssertEqual(JointID.allCases.filter(\.isFingertip).count, 5)
        XCTAssertEqual(Set(JointID.allCases.compactMap(\.finger)), Set(Finger.allCases))
    }

    func testFrameRateMeter() {
        var meter = FrameRateMeter()
        var fps = 0.0
        for index in 0..<120 { fps = meter.tick(at: Double(index) / 60.0) }
        XCTAssertEqual(fps, 60, accuracy: 0.5)
    }

    func testRotationMath() {
        XCTAssertEqual(RotationMath.normalized(-90), 270)
        XCTAssertEqual(RotationMath.normalized(450), 90)
        XCTAssertEqual(RotationMath.normalized(360), 0)
        XCTAssertEqual(RotationMath.combined(base: 90, manual: 270), 0)
        XCTAssertEqual(RotationMath.combined(base: 0, manual: 90), 90)
    }

    // MARK: Keyboard region

    func testUncalibratedRegionSpansTheWholePicture() {
        let region = KeyboardRegion.uncalibrated(firstNote: 36, lastNote: 84)
        XCTAssertEqual(region.whiteKeyCount, 29)
        XCTAssertEqual(region.x(ofNote: 36), 0.5 / 29, accuracy: 1e-9)
        XCTAssertEqual(region.normalize(CGPoint(x: 0.5, y: 0.7)).along, 0.5, accuracy: 1e-9)
        XCTAssertTrue(region.normalize(CGPoint(x: 0.5, y: 0.7)).isInside)
        XCTAssertFalse(region.normalize(CGPoint(x: 0.5, y: 0.1)).isInside)
        XCTAssertEqual(region.normalize(CGPoint(x: 2, y: 2)).along, 1)   // clamped
        XCTAssertEqual(region.normalize(CGPoint(x: -1, y: 2)).along, 0)
    }

    private func samples(slope: Double, intercept: Double, notes: [Int], noise: Double = 0) -> [KeyboardRegionFitter.Sample] {
        notes.enumerated().map { index, note in
            let white = PianoKeys.center(of: note)
            let x = (white - intercept) / slope + (index.isMultiple(of: 2) ? noise : -noise)
            return KeyboardRegionFitter.Sample(x: x, y: 0.6, expectedWhitePosition: white)
        }
    }

    func testFitRecoversAKnownMapping() {
        // 61-key board (C2…C7): camera sees ~14 keys across.
        let firstWhite = Double(PianoKeys.whiteIndex(36))
        let slope = 14.0
        let intercept = firstWhite + 24 - slope * 0.1   // key 24 (relative) lands at x = 0.1... arbitrary but consistent
        let data = samples(slope: slope, intercept: intercept, notes: [60, 62, 64, 65, 67, 55, 53, 52, 50, 48])
        let region = KeyboardRegionFitter.fit(samples: data, firstNote: 36, lastNote: 96)
        XCTAssertNotNil(region)
        XCTAssertEqual(region?.slope ?? 0, slope, accuracy: 1e-6)
        XCTAssertEqual(region?.x(ofNote: 60) ?? 0, (PianoKeys.center(of: 60) - intercept) / slope, accuracy: 1e-6)
        XCTAssertTrue(region?.isCalibrated ?? false)
    }

    func testFitHandlesAReversedCamera() {
        let data = samples(slope: -12, intercept: 80, notes: [60, 62, 64, 65, 67])
        let region = KeyboardRegionFitter.fit(samples: data, firstNote: 36, lastNote: 96)
        XCTAssertEqual(region?.slope ?? 0, -12, accuracy: 1e-6)
        XCTAssertGreaterThan(region?.boundingBox.width ?? 0, 0)
    }

    func testFitRejectsImplausibleData() {
        XCTAssertNil(KeyboardRegionFitter.fit(samples: [], firstNote: 36, lastNote: 96))
        // All fingertips at the same x: no horizontal information.
        let flat = [60, 62, 64, 65, 67].map { KeyboardRegionFitter.Sample(x: 0.5, y: 0.5, expectedWhitePosition: PianoKeys.center(of: $0)) }
        XCTAssertNil(KeyboardRegionFitter.fit(samples: flat, firstNote: 36, lastNote: 96))
        // Hand "spans" the whole picture for 4 keys: slope ≈ 1, absurd.
        XCTAssertNil(KeyboardRegionFitter.fit(samples: samples(slope: 1.0, intercept: 30, notes: [60, 62, 64, 65, 67]), firstNote: 36, lastNote: 96))
        // Noisy, inconsistent samples.
        XCTAssertNil(KeyboardRegionFitter.fit(samples: samples(slope: 14, intercept: 40, notes: [60, 62, 64, 65, 67], noise: 0.25), firstNote: 36, lastNote: 96))
    }

    // MARK: Finger attribution

    private func hand(side: HandSide?, tips: [Finger: Double], confidence: Float = 0.9) -> TrackedHand {
        var joints: [JointID: TrackedJoint] = [:]
        for (finger, x) in tips { joints[JointID.tip(of: finger)] = TrackedJoint(point: CGPoint(x: x, y: 0.5), confidence: confidence) }
        return TrackedHand(id: 0, side: side, joints: joints)
    }

    private func frame(_ hands: [TrackedHand], time: TimeInterval = 10, channel: CameraChannelID = .overhead) -> HandFrame {
        HandFrame(channel: channel, timestamp: time, imageSize: CGSize(width: 1920, height: 1080), hands: hands)
    }

    /// Right hand in C position, calibrated so one white key is 1/20 of the picture wide, C4 centred at x = 0.4.
    private var region: KeyboardRegion {
        let firstWhite = Double(PianoKeys.whiteIndex(36))
        let slope = 20.0
        let intercept = PianoKeys.center(of: 60) - slope * 0.4
        return KeyboardRegion(firstNote: 36, lastNote: 96, slope: slope, intercept: intercept - firstWhite, yMin: 0.4, yMax: 0.8, isCalibrated: true)
    }

    private func cPositionTips(offsetKeys: Double = 0) -> [Finger: Double] {
        var tips: [Finger: Double] = [:]
        for (finger, note) in CalibrationPositions.right { tips[finger] = region.x(ofNote: note) + offsetKeys / 20 }
        return tips
    }

    func testAttributesTheFingerNearestTheStruckKey() {
        let attributor = FingerAttributor()
        let f = frame([hand(side: .right, tips: cPositionTips())])
        for (finger, note) in CalibrationPositions.right {
            let detected = attributor.attribute(note: note, frame: f, region: region)
            XCTAssertEqual(detected?.finger, finger, "note \(note)")
            XCTAssertEqual(detected?.hand, .right)
            XCTAssertEqual(detected?.distance ?? 9, 0, accuracy: 1e-6)
        }
    }

    func testNoFingerNearTheKeyMeansNil() {
        let attributor = FingerAttributor()
        let f = frame([hand(side: .right, tips: cPositionTips())])
        XCTAssertNil(attributor.attribute(note: 80, frame: f, region: region))
        XCTAssertNil(attributor.attribute(note: 60, frame: frame([]), region: region))
    }

    func testToleranceIsAboutOneWhiteKey() {
        let attributor = FingerAttributor()
        let near = frame([hand(side: .right, tips: [.index: region.x(ofNote: 62) + 0.8 / 20])])
        XCTAssertEqual(attributor.attribute(note: 62, frame: near, region: region)?.finger, .index)
        let far = frame([hand(side: .right, tips: [.index: region.x(ofNote: 62) + 1.4 / 20])])
        XCTAssertNil(attributor.attribute(note: 62, frame: far, region: region))
    }

    func testLowConfidenceTipsAreIgnored() {
        let attributor = FingerAttributor()
        let f = frame([hand(side: .right, tips: [.index: region.x(ofNote: 62)], confidence: 0.1)])
        XCTAssertNil(attributor.attribute(note: 62, frame: f, region: region))
    }

    func testTwoHandsPickTheRightOne() {
        let attributor = FingerAttributor()
        let left = hand(side: .left, tips: [.pinky: region.x(ofNote: 48), .thumb: region.x(ofNote: 55)])
        let right = hand(side: .right, tips: cPositionTips())
        let f = frame([left, right])
        XCTAssertEqual(attributor.attribute(note: 48, frame: f, region: region)?.hand, .left)
        XCTAssertEqual(attributor.attribute(note: 48, frame: f, region: region)?.finger, .pinky)
        XCTAssertEqual(attributor.attribute(note: 64, frame: f, region: region)?.hand, .right)
    }

    func testTieIsBrokenByConfidence() {
        let attributor = FingerAttributor()
        let x = region.x(ofNote: 62)
        var joints: [JointID: TrackedJoint] = [:]
        joints[.indexTip] = TrackedJoint(point: CGPoint(x: x, y: 0.5), confidence: 0.5)
        joints[.middleTip] = TrackedJoint(point: CGPoint(x: x + 0.02 / 20, y: 0.5), confidence: 0.95)
        let f = frame([TrackedHand(id: 0, side: .right, joints: joints)])
        XCTAssertEqual(attributor.attribute(note: 62, frame: f, region: region)?.finger, .middle)
    }

    func testMirroredCameraWorksViaNegativeSlope() {
        var reversed = region
        reversed.slope = -20
        reversed.intercept = 90
        var tips: [Finger: Double] = [:]
        for (finger, note) in CalibrationPositions.right { tips[finger] = reversed.x(ofNote: note) }
        let attributor = FingerAttributor()
        let f = frame([hand(side: .right, tips: tips)])
        XCTAssertEqual(attributor.attribute(note: 65, frame: f, region: reversed)?.finger, .ring)
    }

    // MARK: History

    func testHistoryFindsTheNearestFrameWithinTolerance() {
        let history = HandFrameHistory(window: 1.0)
        for index in 0..<10 { history.append(frame([], time: 10 + Double(index) * 0.033)) }
        XCTAssertEqual(history.frame(nearest: 10.1, channel: .overhead)?.timestamp ?? 0, 10.099, accuracy: 0.001)
        XCTAssertNil(history.frame(nearest: 12, channel: .overhead))
        XCTAssertNil(history.frame(nearest: 10.1, channel: .primary))
        XCTAssertTrue(history.hasFrame(atOrAfter: 10.2, channel: .overhead))
        XCTAssertFalse(history.hasFrame(atOrAfter: 10.4, channel: .overhead))
    }

    func testHistoryDropsOldFrames() {
        let history = HandFrameHistory(window: 0.5)
        history.append(frame([], time: 1))
        history.append(frame([], time: 2))
        XCTAssertNil(history.frame(nearest: 1, channel: .overhead, tolerance: 0.1))
        XCTAssertNotNil(history.frame(nearest: 2, channel: .overhead))
    }

    // MARK: Template matching

    private func hand(matching template: HandTemplate, scale: Double = 1, offset: CGPoint = .zero, mirrorX: Bool = false) -> TrackedHand {
        var joints: [JointID: TrackedJoint] = [:]
        let centre = CGPoint(x: template.placement.midX, y: template.placement.midY)
        for joint in JointID.allCases {
            guard var point = template.target(for: joint) else { continue }
            point = CGPoint(x: centre.x + (point.x - centre.x) * scale + offset.x, y: centre.y + (point.y - centre.y) * scale + offset.y)
            if mirrorX { point.x = 1 - point.x }
            joints[joint] = TrackedJoint(point: point, confidence: 0.9)
        }
        return TrackedHand(id: 0, side: template.side, joints: joints)
    }

    func testHandOnThePrintIsAligned() {
        let template = HandTemplate.make(for: .right)
        let match = HandTemplateMatcher.match(frame: frame([hand(matching: template)]), template: template, aspectRatio: 16.0 / 9.0)
        XCTAssertTrue(match.handDetected)
        XCTAssertTrue(match.isAligned)
        XCTAssertGreaterThan(match.score, 0.9)
        XCTAssertEqual(match.tips.count, 5)
    }

    func testSmallerAndSlightlyOffsetHandsStillCount() {
        let template = HandTemplate.make(for: .right)
        let small = hand(matching: template, scale: 0.6, offset: CGPoint(x: 0.03, y: 0.04))
        XCTAssertTrue(HandTemplateMatcher.match(frame: frame([small]), template: template, aspectRatio: 16.0 / 9.0).isAligned)
    }

    func testHandFarAwayOrWrongHandIsNotAligned() {
        let template = HandTemplate.make(for: .right)
        let far = hand(matching: template, offset: CGPoint(x: -0.45, y: 0))
        let farMatch = HandTemplateMatcher.match(frame: frame([far]), template: template, aspectRatio: 16.0 / 9.0)
        XCTAssertTrue(farMatch.handDetected)
        XCTAssertFalse(farMatch.isAligned)

        // A left hand laid over the right-hand print has its thumb on the wrong side.
        let leftTemplate = HandTemplate.make(for: .left)
        let leftHand = hand(matching: leftTemplate, offset: CGPoint(x: template.placement.midX - leftTemplate.placement.midX, y: 0))
        XCTAssertFalse(HandTemplateMatcher.match(frame: frame([leftHand]), template: template, aspectRatio: 16.0 / 9.0).isAligned)

        XCTAssertFalse(HandTemplateMatcher.match(frame: frame([]), template: template, aspectRatio: 16.0 / 9.0).handDetected)
    }

    func testTooTinyOrHugeHandsAreRejected() {
        let template = HandTemplate.make(for: .right)
        XCTAssertFalse(HandTemplateMatcher.match(frame: frame([hand(matching: template, scale: 0.2)]), template: template, aspectRatio: 16.0 / 9.0).isAligned)
        XCTAssertFalse(HandTemplateMatcher.match(frame: frame([hand(matching: template, scale: 3.5)]), template: template, aspectRatio: 16.0 / 9.0).isAligned)
    }

    // MARK: Face

    private func lips(width: Double, cornerLift: Double, openness: Double) -> (outer: [CGPoint], inner: [CGPoint]) {
        // Simple lip outline centred at (0.5, 0.3): corners left/right, top/bottom arcs.
        let cx = 0.5, cy = 0.3
        let left = CGPoint(x: cx - width / 2, y: cy + cornerLift * width)
        let right = CGPoint(x: cx + width / 2, y: cy + cornerLift * width)
        let outer = [left, CGPoint(x: cx - width / 4, y: cy + 0.03), CGPoint(x: cx, y: cy + 0.04), CGPoint(x: cx + width / 4, y: cy + 0.03),
                     right, CGPoint(x: cx + width / 4, y: cy - 0.03), CGPoint(x: cx, y: cy - 0.04 - openness * width * 0.3), CGPoint(x: cx - width / 4, y: cy - 0.03)]
        let inner = [CGPoint(x: cx - width / 3, y: cy), CGPoint(x: cx, y: cy + openness * width * 0.2),
                     CGPoint(x: cx + width / 3, y: cy), CGPoint(x: cx, y: cy - openness * width * 0.2)]
        return (outer, inner)
    }

    func testSmileIsHigherForAWideLiftedMouth() {
        let neutral = lips(width: 0.38, cornerLift: -0.02, openness: 0)
        let smiling = lips(width: 0.55, cornerLift: 0.12, openness: 0)
        let n = FaceExpressionEstimator.estimate(outerLips: neutral.outer, innerLips: neutral.inner)!
        let s = FaceExpressionEstimator.estimate(outerLips: smiling.outer, innerLips: smiling.inner)!
        XCTAssertLessThan(n.smile, 0.2)
        XCTAssertGreaterThan(s.smile, 0.8)
        XCTAssertTrue((0...1).contains(s.smile))
    }

    func testMouthOpenGrowsWithOpenness() {
        let closed = lips(width: 0.4, cornerLift: 0, openness: 0)
        let open = lips(width: 0.4, cornerLift: 0, openness: 1.6)
        XCTAssertLessThan(FaceExpressionEstimator.estimate(outerLips: closed.outer, innerLips: closed.inner)!.mouthOpen, 0.1)
        XCTAssertGreaterThan(FaceExpressionEstimator.estimate(outerLips: open.outer, innerLips: open.inner)!.mouthOpen, 0.5)
    }

    func testDegenerateLipsReturnNil() {
        XCTAssertNil(FaceExpressionEstimator.estimate(outerLips: [], innerLips: []))
        XCTAssertNil(FaceExpressionEstimator.estimate(outerLips: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 8), innerLips: []))
    }
}

final class OverlayGeometryTests: XCTestCase {
    private let video = CGSize(width: 1920, height: 1080)   // 16:9 picture

    func testSameShapeViewMapsStraightThrough() {
        let view = CGSize(width: 960, height: 540)
        for fit in [false, true] {
            let p = OverlayGeometry.viewPoint(CGPoint(x: 0.25, y: 0.75), imageSize: video, viewSize: view, fit: fit)
            XCTAssertEqual(p.x, 240, accuracy: 1e-6)
            XCTAssertEqual(p.y, 405, accuracy: 1e-6)
        }
    }

    /// The bug: a 19.5:9 phone screen shows a 16:9 picture aspect-FILL, cropping the top and bottom. Dots must move with the crop.
    func testWideScreenCropsTheTopAndBottomWhenFilling() {
        let phone = CGSize(width: 2000, height: 921)
        let centre = OverlayGeometry.viewPoint(CGPoint(x: 0.5, y: 0.5), imageSize: video, viewSize: phone, fit: false)
        XCTAssertEqual(centre.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 460.5, accuracy: 1e-6)
        // The picture is scaled to 2000 × 1125, so its top edge is 102 pt above the screen.
        let rect = OverlayGeometry.pictureRect(imageSize: video, viewSize: phone, fit: false)
        XCTAssertEqual(rect.width, 2000, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 1125, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, -102, accuracy: 1e-6)
        // A hand near the bottom of the picture (y = 0.9) is lower on screen than a naive y × height would put it.
        let naive = 0.9 * phone.height
        let mapped = OverlayGeometry.viewPoint(CGPoint(x: 0.5, y: 0.9), imageSize: video, viewSize: phone, fit: false).y
        XCTAssertEqual(mapped - naive, 0.9 * 1125 - 102 - 0.9 * 921, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(mapped - naive), 20, "the old mapping was visibly off")
    }

    func testFitLeavesBarsAndKeepsTheWholePicture() {
        let phone = CGSize(width: 2000, height: 921)
        let rect = OverlayGeometry.pictureRect(imageSize: video, viewSize: phone, fit: true)
        XCTAssertEqual(rect.height, 921, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 921 * 16 / 9, accuracy: 1e-6)
        XCTAssertGreaterThan(rect.minX, 0, "bars at the sides")
        XCTAssertEqual(OverlayGeometry.viewPoint(CGPoint(x: 0, y: 0), imageSize: video, viewSize: phone, fit: true), CGPoint(x: rect.minX, y: 0))
        XCTAssertEqual(OverlayGeometry.viewPoint(CGPoint(x: 1, y: 1), imageSize: video, viewSize: phone, fit: true).y, 921, accuracy: 1e-6)
    }

    func testTallViewCropsTheSidesWhenFilling() {
        let portrait = CGSize(width: 400, height: 900)
        let rect = OverlayGeometry.pictureRect(imageSize: video, viewSize: portrait, fit: false)
        XCTAssertEqual(rect.height, 900, accuracy: 1e-6)
        XCTAssertLessThan(rect.minX, 0)
    }

    func testUnknownImageSizeFallsBackToTheViewSize() {
        let p = OverlayGeometry.viewPoint(CGPoint(x: 0.5, y: 0.5), imageSize: .zero, viewSize: CGSize(width: 100, height: 50), fit: false)
        XCTAssertEqual(p, CGPoint(x: 50, y: 25))
    }
}

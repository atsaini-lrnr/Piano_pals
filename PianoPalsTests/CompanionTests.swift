import XCTest
@testable import PianoPals

final class CompanionProtocolTests: XCTestCase {
    private func sampleHand(side: HandSide?, offset: Double = 0, id: Int = 0) -> TrackedHand {
        var joints: [JointID: TrackedJoint] = [:]
        for (index, jointID) in JointID.allCases.enumerated() {
            joints[jointID] = TrackedJoint(point: CGPoint(x: 0.2 + offset + Double(index) * 0.01, y: 0.4 + Double(index) * 0.005), confidence: 0.5 + Float(index) * 0.02)
        }
        return TrackedHand(id: id, side: side, joints: joints)
    }

    private func sampleFrame(time: Double = 1234.5) -> HandFrame {
        HandFrame(channel: .overhead, timestamp: time, imageSize: CGSize(width: 1920, height: 1080),
                  hands: [sampleHand(side: .left), sampleHand(side: .right, offset: 0.3, id: 1)])
    }

    // MARK: Wire format

    func testFrameSurvivesTheWireWithAllJoints() throws {
        let frame = sampleFrame()
        let data = try CompanionMessage.frame(WireFrame(frame)).encoded()
        guard case .frame(let wire) = try CompanionMessage.decode(data) else { return XCTFail("wrong message") }
        let back = wire.handFrame(channel: .overhead, padTime: 99)
        XCTAssertEqual(back.timestamp, 99, "re-stamped onto the iPad clock")
        XCTAssertEqual(back.imageSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(back.hands.count, 2)
        XCTAssertEqual(back.hands.map(\.side), [.left, .right])
        for (original, received) in zip(frame.hands, back.hands) {
            XCTAssertEqual(received.joints.count, 21)
            for id in JointID.allCases {
                let a = original.joints[id]!, b = received.joints[id]!
                XCTAssertEqual(Double(a.point.x), Double(b.point.x), accuracy: 1e-5)
                XCTAssertEqual(Double(a.point.y), Double(b.point.y), accuracy: 1e-5)
                XCTAssertEqual(a.confidence, b.confidence, accuracy: 1e-6)
            }
        }
    }

    func testMissingJointsStayMissingAndUnknownHandednessSurvives() throws {
        var hand = sampleHand(side: nil)
        hand.joints.removeValue(forKey: .ringTip)
        hand.joints.removeValue(forKey: .wrist)
        let wire = WireHand(hand)
        XCTAssertEqual(wire.side, -1)
        let back = try XCTUnwrap(wire.trackedHand(id: 7))
        XCTAssertNil(back.side)
        XCTAssertEqual(back.id, 7)
        XCTAssertNil(back.joints[.ringTip])
        XCTAssertNil(back.joints[.wrist])
        XCTAssertEqual(back.joints.count, 19)
    }

    func testMalformedHandIsRejected() {
        XCTAssertNil(WireHand(side: 1, joints: [0.1, 0.2]).trackedHand(id: 0))
    }

    func testEveryMessageTypeRoundTrips() throws {
        let messages: [CompanionMessage] = [
            .hello(name: "Atul's iPhone", platform: "iPhone", version: CompanionConstants.protocolVersion),
            .frame(WireFrame(sampleFrame())),
            .preview(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), w: 480, h: 270),
            .ping(id: 42, sent: 10.25), .pong(id: 42, echoed: 10.25, phoneTime: 5000.5),
            .control(rotation: 90, flip: true), .bye
        ]
        for message in messages {
            XCTAssertEqual(try CompanionMessage.decode(message.encoded()), message)
        }
        XCTAssertThrowsError(try CompanionMessage.decode(Data("garbage".utf8)))
    }

    func testAFrameIsSmallEnoughForSixtyUpdatesASecond() throws {
        let bytes = try CompanionMessage.frame(WireFrame(sampleFrame())).encoded().count
        XCTAssertLessThan(bytes, 8_000, "two hands = \(bytes) bytes")
        XCTAssertLessThan(Double(bytes) * 60, 500_000, "under 0.5 MB/s at 60 fps")
    }

    func testServiceNameIsValidForBonjour() {
        let type = CompanionSecurity.bonjourType
        XCTAssertTrue(type.hasPrefix("_") && type.hasSuffix("._tcp"))
        let name = String(type.dropFirst().dropLast(5))
        XCTAssertLessThanOrEqual(name.count, 15)
        XCTAssertTrue(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    // MARK: Clock sync

    func testOffsetIsRecoveredFromTheLowestLatencyRoundTrip() {
        // The iPhone's clock runs 5000 s ahead. Round trips vary; the quick ones reveal the truth.
        var sync = ClockSync()
        let trueOffset = 5000.0
        XCTAssertFalse(sync.hasEstimate)
        let rtts = [0.080, 0.012, 0.150, 0.006, 0.040, 0.300]
        for (i, rtt) in rtts.enumerated() {
            let sent = 100.0 + Double(i)
            // Asymmetric delay: the outbound leg takes 60 % of the round trip.
            let phone = sent + rtt * 0.6 + trueOffset
            sync.record(sentPad: sent, phoneTime: phone, receivedPad: sent + rtt)
        }
        XCTAssertEqual(sync.roundTrip ?? 0, 0.006, accuracy: 1e-9)
        XCTAssertEqual(sync.offset ?? 0, trueOffset, accuracy: 0.003, "within the asymmetry error of the best round trip")
        // A frame stamped 5123.4 on the iPhone happened at 123.4 on the iPad.
        XCTAssertEqual(sync.padTime(forPhoneTime: 5123.4, arrival: 999), 123.4, accuracy: 0.003)
    }

    func testBeforeAnyPongTheArrivalTimeIsUsed() {
        let sync = ClockSync()
        XCTAssertEqual(sync.padTime(forPhoneTime: 5123.4, arrival: 200), 200 - 0.03, accuracy: 1e-9)
    }

    func testImplausibleSamplesAreIgnored() {
        var sync = ClockSync()
        sync.record(sentPad: 10, phoneTime: 20, receivedPad: 9)      // negative round trip
        sync.record(sentPad: 10, phoneTime: 20, receivedPad: 13)     // 3 s round trip
        XCTAssertFalse(sync.hasEstimate)
    }

    func testOldSamplesAgeOut() {
        var sync = ClockSync()
        sync.record(sentPad: 0, phoneTime: 1000.001, receivedPad: 0.002)   // great sample, offset ≈ 1000
        for i in 1...20 { sync.record(sentPad: Double(i), phoneTime: Double(i) + 2000.05, receivedPad: Double(i) + 0.1) }   // clock drifted to ≈ 2000
        XCTAssertEqual(sync.offset ?? 0, 2000, accuracy: 0.1, "the stale low-latency sample no longer wins")
    }

    // MARK: Channel behaviour with a remote camera

    func testRemoteChannelPresentsLikeACamera() {
        let channel = CameraChannel(id: .overhead)
        XCTAssertFalse(channel.isRemote)
        channel.attachRemote(name: "Atul's iPhone")
        XCTAssertTrue(channel.isRemote)
        XCTAssertEqual(channel.state, .running)
        XCTAssertEqual(channel.deviceInfo?.kind, .companion)
        XCTAssertEqual(channel.deviceInfo?.name, "Atul's iPhone")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 270)).image { _ in }
        channel.setRemotePreview(image)
        XCTAssertEqual(channel.videoSize.width / channel.videoSize.height, 480.0 / 270.0, accuracy: 0.01)

        var received: [HandFrame] = []
        let lock = NSLock()
        channel.onHandFrame = { frame in lock.lock(); received.append(frame); lock.unlock() }
        channel.publishRemote(frame: sampleFrame())
        lock.lock(); XCTAssertEqual(received.count, 1); lock.unlock()

        channel.detachRemote()
        XCTAssertFalse(channel.isRemote)
        XCTAssertEqual(channel.state, .noCamera)
        XCTAssertNil(channel.remotePreview)
        XCTAssertNil(channel.deviceInfo)
    }

    func testPreviewJPEGEncoderProducesSmallPictures() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        let result = try XCTUnwrap(PreviewEncoder().jpeg(from: pixels))
        XCTAssertEqual(result.width, 480)
        XCTAssertEqual(result.height, 270)
        XCTAssertLessThan(result.data.count, 60_000, "fits the 60 KB limit used when sending")
        XCTAssertNotNil(UIImage(data: result.data))
    }

    func testLinkStartsIdleAndRemembersNothingByDefault() {
        let link = RemoteCameraLink()
        XCTAssertEqual(link.state, .idle)
        XCTAssertTrue(link.nearby.isEmpty)
    }
}

import Network

/// Exercises the real encrypted transport (TLS-PSK + length-prefixed framing) over the loopback interface, so the protocol,
/// pairing-code check and framing are verified without needing two devices or Bonjour.
final class CompanionTransportTests: XCTestCase {
    private func loopback(_ code: String) -> NWParameters {
        let parameters = CompanionSecurity.parameters(code: code)
        parameters.requiredInterfaceType = .loopback
        parameters.includePeerToPeer = false
        return parameters
    }

    private final class Server {
        let listener: NWListener
        let queue = DispatchQueue(label: "test.server")
        var connections: [FramedConnection] = []
        var received = Locked<[CompanionMessage]>([])
        let ready = XCTestExpectation(description: "listener ready")
        var port: NWEndpoint.Port?

        init(parameters: NWParameters) throws {
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let framed = FramedConnection(connection: connection, queue: self.queue)
                framed.onMessage = { [weak framed, weak self] message in
                    self?.received.withLock { $0.append(message) }
                    if case .ping(let id, let sent) = message { framed?.send(.pong(id: id, echoed: sent, phoneTime: 777)) }
                }
                self.connections.append(framed)
                framed.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.port = self?.listener.port; self?.ready.fulfill() }
            }
            listener.start(queue: queue)
        }

        func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
    }

    private func connect(to port: NWEndpoint.Port, code: String) -> (FramedConnection, Locked<[CompanionMessage]>, Locked<[String]>) {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: loopback(code))
        let framed = FramedConnection(connection: connection, queue: DispatchQueue(label: "test.client"))
        let messages = Locked<[CompanionMessage]>([])
        let states = Locked<[String]>([])
        framed.onMessage = { message in messages.withLock { $0.append(message) } }
        framed.onState = { state in states.withLock { $0.append(String(describing: state)) } }
        framed.start()
        return (framed, messages, states)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testMessagesTravelEncryptedAndIntactBothWays() throws {
        let code = "12345678"
        let server = try Server(parameters: loopback(code))
        defer { server.stop() }
        wait(for: [server.ready], timeout: 5)
        let port = try XCTUnwrap(server.port)

        let (client, replies, states) = connect(to: port, code: code)
        defer { client.cancel() }
        XCTAssertTrue(waitUntil { states.current.contains("ready") }, "TLS-PSK handshake completes with the right code: \(states.current)")

        client.send(.ping(id: 9, sent: 42.5))
        XCTAssertTrue(waitUntil { replies.current.contains(.pong(id: 9, echoed: 42.5, phoneTime: 777)) }, "round trip works")

        // A large preview and many frames, in order.
        let jpeg = Data((0..<50_000).map { UInt8($0 % 251) })
        client.send(.preview(jpeg: jpeg, w: 480, h: 270))
        for i in 0..<30 { client.send(.frame(WireFrame(t: Double(i), w: 1920, h: 1080, hands: []))) }
        XCTAssertTrue(waitUntil { server.received.current.count >= 32 }, "all messages arrive")
        let got = server.received.current
        XCTAssertEqual(got[1], .preview(jpeg: jpeg, w: 480, h: 270), "50 KB preview is byte-for-byte intact")
        let times: [Double] = got.compactMap { if case .frame(let f) = $0 { return f.t } else { return nil } }
        XCTAssertEqual(times, (0..<30).map(Double.init), "frames keep their order")
    }

    func testAWrongPairingCodeCannotConnectOrSendAnything() throws {
        let server = try Server(parameters: loopback("12345678"))
        defer { server.stop() }
        wait(for: [server.ready], timeout: 5)
        let port = try XCTUnwrap(server.port)

        let (intruder, _, states) = connect(to: port, code: "87654321")
        defer { intruder.cancel() }
        intruder.send(.ping(id: 1, sent: 1))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(states.current.contains("ready"), "handshake must fail: \(states.current)")
        XCTAssertTrue(server.received.current.isEmpty, "the iPhone never sees a message from a device without the code")
    }

    func testOversizedFramesAreRefused() throws {
        let server = try Server(parameters: loopback("11112222"))
        defer { server.stop() }
        wait(for: [server.ready], timeout: 5)
        let (client, _, states) = connect(to: try XCTUnwrap(server.port), code: "11112222")
        defer { client.cancel() }
        XCTAssertTrue(waitUntil { states.current.contains("ready") })
        // Hand-craft a header claiming 5 MB: the receiver must drop the connection rather than allocate it.
        var length = UInt32(5_000_000).bigEndian
        client.connection.send(content: Data(bytes: &length, count: 4), completion: .contentProcessed { _ in })
        XCTAssertTrue(waitUntil { server.connections.first.map { String(describing: $0.connection.state).contains("cancel") } ?? false },
                      "oversized frame closes the connection")
        XCTAssertTrue(server.received.current.isEmpty)
    }

    func testPairingCodeHelpers() {
        XCTAssertTrue(CompanionSecurity.isValid("12345678"))
        XCTAssertFalse(CompanionSecurity.isValid("1234567"))
        XCTAssertFalse(CompanionSecurity.isValid("1234567a"))
        XCTAssertEqual(CompanionSecurity.normalize("1234 5678"), "12345678")
        XCTAssertEqual(CompanionSecurity.normalize("1234-5678 "), "12345678")
        XCTAssertEqual(CompanionSecurity.display("12345678"), "1234 5678")
        for _ in 0..<50 { XCTAssertTrue(CompanionSecurity.isValid(CompanionSecurity.makeCode())) }
        XCTAssertEqual(CompanionSecurity.presharedKey(for: "12345678"), CompanionSecurity.presharedKey(for: "12345678"))
        XCTAssertNotEqual(CompanionSecurity.presharedKey(for: "12345678"), CompanionSecurity.presharedKey(for: "12345679"))
        XCTAssertEqual(CompanionSecurity.presharedKey(for: "12345678").count, 32)
    }

    func testPairingKeychainRoundTrip() {
        let account = "test-\(UUID().uuidString)"
        XCTAssertNil(PairingKeychain.load(account: account))
        PairingKeychain.save("12345678", account: account)
        XCTAssertEqual(PairingKeychain.load(account: account), "12345678")
        PairingKeychain.save("87654321", account: account)
        XCTAssertEqual(PairingKeychain.load(account: account), "87654321", "saving replaces")
        PairingKeychain.delete(account: account)
        XCTAssertNil(PairingKeychain.load(account: account))
    }
}

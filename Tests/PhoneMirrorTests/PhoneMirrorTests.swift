import AppKit
import XCTest
@testable import PhoneMirror

final class PhoneMirrorTests: XCTestCase {
    func testDeviceListParsingKeepsOnlineAndOfflineDevices() {
        let output = """
        5NC0225C02000010        USB    Offline     localhost
        FMRGK24604000114        USB    Connected   localhost
        """
        let devices = MirrorDevice.parseHDCList(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].state, .offline)
        XCTAssertEqual(devices[1].serial, "FMRGK24604000114")
        XCTAssertTrue(devices[1].state.isConnected)
    }

    func testADBDeviceListParsing() {
        let output = """
        List of devices attached
        b51d5933 device usb:1179648X product:dada model:24129PN74C device:dada transport_id:5
        emulator-5554 offline transport_id:7
        """
        let devices = MirrorDevice.parseADBList(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].platform, .android)
        XCTAssertEqual(devices[0].serial, "b51d5933")
        XCTAssertEqual(devices[0].advertisedModel, "24129PN74C")
        XCTAssertEqual(devices[1].state, .offline)
    }

    func testAndroidPackageInfoParsing() {
        let output = """
        package: name='com.example.reader' versionCode='42' versionName='1.2.0'
        launchable-activity: name='com.example.reader.MainActivity' label='Reader' icon=''
        """
        XCTAssertEqual(
            ADBClient.parsePackageInfo(output),
            AppPackageInfo(
                identifier: "com.example.reader", moduleName: nil,
                entryPoint: "com.example.reader.MainActivity"
            )
        )
    }

    func testHarmonyPackageInfoParsing() {
        let manifest = Data(#"{"app":{"bundleName":"com.example.reader"},"module":{"name":"entry","mainElement":"EntryAbility","abilities":[{"name":"EntryAbility"}]}}"#.utf8)
        XCTAssertEqual(
            HDCClient.parsePackageInfo(manifest),
            AppPackageInfo(
                identifier: "com.example.reader", moduleName: "entry", entryPoint: "EntryAbility"
            )
        )
    }

    func testMacWindowAndQuitShortcutsAreNotConsumedByMirrorCanvas() {
        XCTAssertFalse(MirrorCanvasView.handlesKeyEvent(keyCode: 12, modifiers: .command)) // Command-Q
        XCTAssertFalse(MirrorCanvasView.handlesKeyEvent(keyCode: 13, modifiers: .command)) // Command-W
        XCTAssertTrue(MirrorCanvasView.handlesKeyEvent(keyCode: 9, modifiers: .command))   // Command-V
        XCTAssertTrue(MirrorCanvasView.handlesKeyEvent(keyCode: 53, modifiers: []))        // Escape
    }

    func testIOSDeviceListParsing() {
        let devices = MirrorDevice.parseIOSList("00008150-001859DE1E44401C\n")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].platform, .ios)
        XCTAssertEqual(devices[0].serial, "00008150-001859DE1E44401C")
        XCTAssertEqual(devices[0].transport, "USB")
        XCTAssertTrue(devices[0].state.isConnected)
    }

    func testIOSDiscoveryAndDetailsOnConnectedDevice() async throws {
        guard let deviceID = ProcessInfo.processInfo.environment["PHONE_MIRROR_IOS_TEST_DEVICE"],
              !deviceID.isEmpty else {
            throw XCTSkip("Set PHONE_MIRROR_IOS_TEST_DEVICE to run the real-device iOS test")
        }
        let client = IOSClient()
        let devices = await client.listDevices()
        guard let device = devices.first(where: { $0.serial == deviceID }) else {
            XCTFail("iOS device is not connected")
            return
        }
        let details = await client.details(for: device)
        XCTAssertEqual(device.platform, .ios)
        XCTAssertFalse(details.model.isEmpty)
        XCTAssertTrue(details.version.hasPrefix("iOS"))
    }

    func testADBResolutionParsingUsesLastOverride() {
        let output = "Physical size: 1080x2400\nOverride size: 1200x2670"
        XCTAssertEqual(ADBClient.parseResolution(output), CGSize(width: 1200, height: 2670))
    }

    func testScrcpyPacketDemuxerParsesSessionAndFrame() async {
        let probe = ScrcpyDemuxerProbe()
        let demuxer = ScrcpyPacketDemuxer(
            onPacket: { data, pts, isFrame in probe.receive(data: data, pts: pts, isFrame: isFrame) },
            onVideoSize: { width, height in probe.setSize(width: width, height: height) }
        )
        var bytes = Data("h264".utf8)
        bytes.appendBigEndian(UInt32(0x80000000))
        bytes.appendBigEndian(UInt32(576))
        bytes.appendBigEndian(UInt32(1280))
        bytes.appendBigEndian(UInt64(42))
        bytes.appendBigEndian(UInt32(3))
        bytes.append(contentsOf: [0x65, 0x01, 0x02])
        demuxer.consume(Data(bytes.prefix(9)))
        demuxer.consume(Data(bytes.dropFirst(9)))

        XCTAssertEqual(probe.size, CGSize(width: 576, height: 1280))
        XCTAssertEqual(probe.payload, Data([0x65, 0x01, 0x02]))
        XCTAssertEqual(probe.pts, 42)
        XCTAssertTrue(probe.isFrame)
    }

    func testHarmonyCompanionDemuxerHandlesFragmentedConfigAndFrame() {
        let probe = HarmonyVideoProbe()
        let demuxer = HarmonyCompanionPacketDemuxer { data, pts, isFrame in
            probe.receive(data: data, pts: pts, isFrame: isFrame)
        }
        let config = Self.harmonyPacket(payload: Data([0x00, 0x00, 0x00, 0x01, 0x67]), flags: 1 << 3, pts: 0)
        let frame = Self.harmonyPacket(payload: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x01]), flags: 1 << 1, pts: 16_666)
        let stream = config + frame

        demuxer.consume(Data(stream.prefix(7)))
        demuxer.consume(Data(stream.dropFirst(7).prefix(19)))
        demuxer.consume(Data(stream.dropFirst(26)))

        XCTAssertEqual(probe.packets.count, 2)
        XCTAssertFalse(probe.packets[0].isFrame)
        XCTAssertTrue(probe.packets[1].isFrame)
        XCTAssertEqual(probe.packets[1].pts, 16_666)
        XCTAssertEqual(probe.packets[1].data, Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x01]))
        XCTAssertEqual(demuxer.bufferedByteCount, 0)
    }

    func testHarmonyCompanionDemuxerSkipsNonVideoPackets() {
        let probe = HarmonyVideoProbe()
        let demuxer = HarmonyCompanionPacketDemuxer { data, pts, isFrame in
            probe.receive(data: data, pts: pts, isFrame: isFrame)
        }
        demuxer.consume(Self.harmonyPacket(payload: Data("file.txt".utf8), type: 30, flags: 0, pts: 0))
        XCTAssertTrue(probe.packets.isEmpty)
        XCTAssertEqual(demuxer.bufferedByteCount, 0)
    }

    func testHarmonyCastingDemuxerHandlesFragmentedFrames() {
        let probe = HarmonyVideoProbe()
        let demuxer = HarmonyCastingPacketDemuxer { data, pts, isFrame in
            probe.receive(data: data, pts: pts, isFrame: isFrame)
        }
        let config = Self.harmonyCastingPacket(
            payload: Data([0, 0, 0, 1, 0x67, 0x64]), flags: 8, pts: 10
        )
        let frame = Self.harmonyCastingPacket(
            payload: Data([0, 0, 0, 1, 0x65, 0x88]), flags: 2, pts: 20
        )
        let stream = config + frame
        demuxer.consume(Data(stream.prefix(5)))
        demuxer.consume(Data(stream.dropFirst(5).prefix(16)))
        demuxer.consume(Data(stream.dropFirst(21)))

        XCTAssertEqual(probe.packets.count, 2)
        XCTAssertFalse(probe.packets[0].isFrame)
        XCTAssertEqual(probe.packets[0].pts, 10)
        XCTAssertTrue(probe.packets[1].isFrame)
        XCTAssertEqual(probe.packets[1].pts, 20)
        XCTAssertEqual(demuxer.bufferedByteCount, 0)
    }

    func testHarmonyRPCReaderHandlesFragmentedResponse() async throws {
        let reader = HarmonyRPCReader()
        var packet = Data("_uitestkit_rpc_message_head_".utf8)
        let payload = Data(#"{"result":null}"#.utf8)
        packet.appendBigEndian(UInt32(77))
        packet.appendBigEndian(UInt32(payload.count))
        packet.append(payload)
        packet.append(Data("_uitestkit_rpc_message_tail_".utf8))

        let response = try await withCheckedThrowingContinuation { continuation in
            reader.register(id: 77, timeout: 1, continuation: continuation)
            reader.consume(Data(packet.prefix(11)))
            reader.consume(Data(packet.dropFirst(11)))
        }
        XCTAssertEqual(response, payload)
        XCTAssertEqual(reader.bufferedByteCount, 0)
    }

    func testAndroidTouchProtocolMessage() {
        let message = ADBClient.touchMessage(
            action: 2,
            point: CGPoint(x: 0.25, y: 0.75),
            resolution: CGSize(width: 1200, height: 2670)
        )
        XCTAssertEqual(message.count, 32)
        XCTAssertEqual(message[0], 2)
        XCTAssertEqual(message[1], 2)
        XCTAssertEqual(message.readUInt32(at: 10), 300)
        XCTAssertEqual(message.readUInt32(at: 14), 2003)
        XCTAssertEqual(message.readUInt16(at: 18), 1200)
        XCTAssertEqual(message.readUInt16(at: 20), 2670)
        XCTAssertEqual(message.readUInt16(at: 22), UInt16.max)
    }

    func testAndroidScrollProtocolClampsAxis() {
        let message = ADBClient.scrollMessage(
            point: CGPoint(x: 0.5, y: 0.5),
            deltaX: -64,
            deltaY: 64,
            resolution: CGSize(width: 1080, height: 2400)
        )
        XCTAssertEqual(message.count, 21)
        XCTAssertEqual(message[0], 3)
        XCTAssertEqual(Int16(bitPattern: message.readUInt16(at: 13)), -32_767)
        XCTAssertEqual(Int16(bitPattern: message.readUInt16(at: 15)), 32_767)
    }

    func testClampedMappingKeepsDragInsideScreen() {
        let rect = CGRect(x: 100, y: 100, width: 300, height: 600)
        XCTAssertEqual(GeometryMapper.normalizedClamped(CGPoint(x: 10, y: 900), contentRect: rect), CGPoint(x: 0, y: 0))
        XCTAssertEqual(GeometryMapper.normalizedClamped(CGPoint(x: 900, y: 10), contentRect: rect), CGPoint(x: 1, y: 1))
    }

    func testResolutionParsingUsesActiveMode() {
        let output = """
        activeModes<id, W, H, RS>:    512, 1260, 2720, 60
        Bounds<L,T,W,H>:              0, 0, 1260, 2720,
        """
        XCTAssertEqual(HDCClient.parseResolution(output), CGSize(width: 1260, height: 2720))
    }

    func testResolutionParsingTracksSnapshotRotation() {
        let output = "process: display 0, file type: jpeg, width: 2720, height: 1260"
        XCTAssertEqual(HDCClient.parseResolution(output), CGSize(width: 2720, height: 1260))
    }

    func testBalancedQualityPreservesAspectRatio() {
        let result = StreamQuality.balanced.captureSize(for: CGSize(width: 1260, height: 2720))
        XCTAssertEqual(result?.height, 1360)
        XCTAssertEqual(result?.width, 630)
    }

    func testAspectFitAndCoordinateMappingForPortraitScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rect = GeometryMapper.aspectFitRect(contentSize: CGSize(width: 400, height: 800), in: bounds)
        XCTAssertEqual(rect, CGRect(x: 250, y: 0, width: 300, height: 600))
        XCTAssertEqual(GeometryMapper.normalized(CGPoint(x: 400, y: 300), contentRect: rect), CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(GeometryMapper.normalized(CGPoint(x: 100, y: 300), contentRect: rect))
    }

    func testMirrorStageUsesPhoneAspectWithoutInternalSideBars() {
        let layout = MirrorStageLayout.calculate(
            container: CGSize(width: 900, height: 1_400),
            contentSize: CGSize(width: 630, height: 1_360)
        )
        XCTAssertEqual(layout.railWidth, 56)
        XCTAssertEqual(layout.canvasSize.width / layout.canvasSize.height, 630.0 / 1_360.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(layout.canvasSize.width + 56 + 18 + 48, 900.01)
        XCTAssertLessThanOrEqual(layout.canvasSize.height + 44, 1_400.01)
    }

    func testCaptureSizeLeavesSmallScreenUntouched() {
        XCTAssertEqual(StreamQuality.sharp.captureSize(for: CGSize(width: 720, height: 1280)), CGSize(width: 720, height: 1280))
        XCTAssertNil(StreamQuality.original.captureSize(for: CGSize(width: 1260, height: 2720)))
    }

    func testMediaURIParsing() {
        let output = """
        find 1 result
        uri
        \"file://media/Photo/286/VID_123/PhoneMirror_001.mp4\"
        """
        XCTAssertEqual(
            HDCClient.parseMediaURI(output),
            "file://media/Photo/286/VID_123/PhoneMirror_001.mp4"
        )
    }

    func testClipboardArtifactURLHasExpectedType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ClipboardFileStore.makeArtifactURL(prefix: "Recording", extension: "mp4", root: root)
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testClipboardContainsFileURLInsteadOfPathText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ClipboardFileStore.makeArtifactURL(prefix: "Screenshot", extension: "png", root: root)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PhoneMirrorTests.\(UUID().uuidString)"))

        XCTAssertTrue(ClipboardFileStore.copyFile(url, to: pasteboard))
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(urls?.first?.standardizedFileURL, url.standardizedFileURL)
    }

    func testSystemRecordingRoundTripOnConnectedDevice() async throws {
        guard let deviceID = ProcessInfo.processInfo.environment["PHONE_MIRROR_HARMONY_TEST_DEVICE"], !deviceID.isEmpty else {
            throw XCTSkip("Set PHONE_MIRROR_HARMONY_TEST_DEVICE to run the real-device recording test")
        }
        let client = HDCClient()
        let touchPrepared = await client.prepareRealtimeTouch(deviceID: deviceID)
        XCTAssertTrue(touchPrepared)
        let resolution = CGSize(width: 1260, height: 2720)
        let down = await client.send(.touchDown(CGPoint(x: 0.01, y: 0.5)), to: deviceID, resolution: resolution)
        let move = await client.send(.touchMove(CGPoint(x: 0.02, y: 0.5)), to: deviceID, resolution: resolution)
        let up = await client.send(.touchUp(CGPoint(x: 0.02, y: 0.5)), to: deviceID, resolution: resolution)
        XCTAssertTrue(down)
        XCTAssertTrue(move)
        XCTAssertTrue(up)
        await client.stopRealtimeTouch(deviceID: deviceID)
        let filename = "PhoneMirror_harmony_integration_\(UUID().uuidString).mp4"
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await client.startSystemRecording(deviceID: deviceID, filename: filename)
        try await Task.sleep(for: .seconds(2))
        let mediaURI = try await client.stopSystemRecordingAndReceive(
            deviceID: deviceID,
            filename: filename,
            destination: localURL
        )

        XCTAssertTrue(HDCClient.isMP4File(localURL))
        XCTAssertGreaterThan((try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1_024)
        await MainActor.run {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("PhoneMirrorIntegration.\(UUID().uuidString)"))
            XCTAssertTrue(ClipboardFileStore.copyFile(localURL, to: pasteboard))
            XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        }
        await client.deleteMediaAsset(deviceID: deviceID, mediaURI: mediaURI)
    }

    func testHarmonyRealtimeScrollChangesVisibleContent() async throws {
        guard ProcessInfo.processInfo.environment["PHONE_MIRROR_VERIFY_SCROLL"] == "1",
              let deviceID = ProcessInfo.processInfo.environment["PHONE_MIRROR_HARMONY_TEST_DEVICE"],
              !deviceID.isEmpty else {
            throw XCTSkip("Set PHONE_MIRROR_VERIFY_SCROLL=1 to run the visible scroll test")
        }
        let client = HDCClient()
        let resolution = CGSize(width: 1260, height: 2720)
        let before = try await client.capture(deviceID: deviceID, quality: .balanced).data
        let prepared = await client.prepareRealtimeTouch(deviceID: deviceID)
        XCTAssertTrue(prepared)
        let points = stride(from: 0.72, through: 0.36, by: -0.06).map { CGPoint(x: 0.5, y: $0) }
        let down = await client.send(.touchDown(points[0]), to: deviceID, resolution: resolution)
        var moves = true
        for point in points.dropFirst() {
            moves = await client.send(.touchMove(point), to: deviceID, resolution: resolution) && moves
        }
        let up = await client.send(.touchUp(points.last!), to: deviceID, resolution: resolution)
        try? await Task.sleep(for: .milliseconds(500))
        let after = try await client.capture(deviceID: deviceID, quality: .balanced).data
        XCTAssertTrue(down && moves && up)
        XCTAssertNotEqual(before, after)

        _ = await client.send(.touchDown(points.last!), to: deviceID, resolution: resolution)
        for point in points.reversed().dropFirst() {
            _ = await client.send(.touchMove(point), to: deviceID, resolution: resolution)
        }
        _ = await client.send(.touchUp(points[0]), to: deviceID, resolution: resolution)
        await client.stopRealtimeTouch(deviceID: deviceID)
    }

    func testHarmonyH264StreamOnConnectedDevice() async throws {
        guard let deviceID = ProcessInfo.processInfo.environment["PHONE_MIRROR_HARMONY_TEST_DEVICE"],
              !deviceID.isEmpty else {
            throw XCTSkip("Set PHONE_MIRROR_HARMONY_TEST_DEVICE to run the real-device H.264 test")
        }
        let client = HDCClient()
        let probe = HarmonyStreamProbe()
        try await client.startHarmonyStream(
            deviceID: deviceID,
            onH264: { data, _, isFrame in probe.receive(data: data, isFrame: isFrame) },
            onExit: {}
        )
        defer { Task { await client.stopHarmonyStream(deviceID: deviceID) } }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, probe.frameCount < 10 {
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(probe.sawCodecConfig)
        XCTAssertGreaterThanOrEqual(probe.frameCount, 10)
        await client.stopHarmonyStream(deviceID: deviceID)
        let touchPrepared = await client.prepareRealtimeTouch(deviceID: deviceID)
        XCTAssertTrue(touchPrepared)
        await client.stopRealtimeTouch(deviceID: deviceID)
    }

    private static func harmonyPacket(
        payload: Data, type: UInt8 = 1, flags: UInt16, pts: UInt64
    ) -> Data {
        var packet = Data()
        packet.appendBigEndian(UInt32(0x484D434D))
        packet.append(1)
        packet.append(type)
        packet.appendBigEndian(flags)
        packet.appendBigEndian(UInt32(payload.count))
        packet.appendBigEndian(pts)
        packet.append(payload)
        return packet
    }

    private static func harmonyCastingPacket(payload: Data, flags: UInt8, pts: UInt64) -> Data {
        var packet = Data()
        packet.appendBigEndian(UInt32(9 + payload.count))
        packet.append(flags)
        packet.appendBigEndian(pts)
        packet.append(payload)
        return packet
    }

    func testAndroidStreamScreenshotAndRecordingOnConnectedDevice() async throws {
        guard let deviceID = ProcessInfo.processInfo.environment["PHONE_MIRROR_ANDROID_TEST_DEVICE"], !deviceID.isEmpty else {
            throw XCTSkip("Set PHONE_MIRROR_ANDROID_TEST_DEVICE to run the real-device Android test")
        }
        let client = ADBClient()
        let devices = await client.listDevices()
        guard let device = devices.first(where: { $0.serial == deviceID && $0.state.isConnected }) else {
            XCTFail("Android device is not connected")
            return
        }
        let details = await client.details(for: device)
        XCTAssertGreaterThan(details.resolution.height, 0)

        let screenshot = try await client.capture(deviceID: deviceID)
        XCTAssertGreaterThan(screenshot.count, 128)
        XCTAssertNotNil(NSImage(data: screenshot))

        let streamProbe = AndroidStreamProbe()
        try await client.startStream(
            deviceID: deviceID, quality: .balanced,
            onH264: { data, _, isFrame in Task { await streamProbe.receive(data: data, isFrame: isFrame) } },
            onVideoSize: { width, height in Task { await streamProbe.setSize(width: width, height: height) } },
            onExit: {}
        )
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, await streamProbe.frameCount < 3 { try? await Task.sleep(for: .milliseconds(200)) }
        let streamResult = await streamProbe.result
        XCTAssertGreaterThanOrEqual(streamResult.frames, 3)
        XCTAssertNotNil(streamResult.size)
        let touchDown = await client.send(.touchDown(CGPoint(x: 0.01, y: 0.5)), to: deviceID, resolution: details.resolution)
        let touchMove = await client.send(.touchMove(CGPoint(x: 0.011, y: 0.5)), to: deviceID, resolution: details.resolution)
        let touchUp = await client.send(.touchUp(CGPoint(x: 0.011, y: 0.5)), to: deviceID, resolution: details.resolution)
        XCTAssertTrue(touchDown)
        XCTAssertTrue(touchMove)
        XCTAssertTrue(touchUp)

        let filename = "PhoneMirror_android_integration_\(UUID().uuidString).mp4"
        let remote = "/sdcard/Movies/\(filename)"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: local) }
        try await client.startSystemRecording(deviceID: deviceID, remotePath: remote, resolution: details.resolution)
        try await Task.sleep(for: .seconds(2))
        try await client.stopSystemRecordingAndReceive(deviceID: deviceID, remotePath: remote, destination: local)
        await client.stopStream(deviceID: deviceID)
        XCTAssertTrue(HDCClient.isMP4File(local))
        XCTAssertGreaterThan((try local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1_024)
    }
}

private actor AndroidStreamProbe {
    private(set) var frameCount = 0
    private var videoSize: CGSize?

    func receive(data: Data, isFrame: Bool) {
        if isFrame, !data.isEmpty { frameCount += 1 }
    }

    func setSize(width: Int, height: Int) { videoSize = CGSize(width: width, height: height) }

    var result: (frames: Int, size: CGSize?) { (frameCount, videoSize) }
}

private final class HarmonyVideoProbe: @unchecked Sendable {
    struct Packet {
        let data: Data
        let pts: UInt64
        let isFrame: Bool
    }

    private let lock = NSLock()
    private var values: [Packet] = []

    func receive(data: Data, pts: UInt64, isFrame: Bool) {
        lock.lock()
        values.append(Packet(data: data, pts: pts, isFrame: isFrame))
        lock.unlock()
    }

    var packets: [Packet] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class HarmonyStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var codec = false

    func receive(data: Data, isFrame: Bool) {
        lock.lock()
        if isFrame, !data.isEmpty { frames += 1 }
        if !isFrame, !data.isEmpty { codec = true }
        lock.unlock()
    }

    var frameCount: Int { lock.withLock { frames } }
    var sawCodecConfig: Bool { lock.withLock { codec } }
}

private final class ScrcpyDemuxerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var size: CGSize?
    private(set) var payload: Data?
    private(set) var pts: UInt64?
    private(set) var isFrame = false

    func receive(data: Data, pts: UInt64, isFrame: Bool) {
        lock.lock(); defer { lock.unlock() }
        payload = data; self.pts = pts; self.isFrame = isFrame
    }

    func setSize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        size = CGSize(width: width, height: height)
    }
}

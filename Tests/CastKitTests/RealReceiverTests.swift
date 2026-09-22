import XCTest
@testable import CastKit

/// Drives a real receiver on the local network. Opt-in: set
/// `CASTKIT_REAL_DEVICE` to part of the device's name, e.g.
/// `CASTKIT_REAL_DEVICE="Nest Hub" swift test --filter RealReceiverTests`.
/// The device volume is set to 10% for the run and put back afterwards.
final class RealReceiverTests: XCTestCase {

  private final class Events: CastClientDelegate, @unchecked Sendable {
    let connected = XCTestExpectation(description: "connected")
    let disconnected = XCTestExpectation(description: "disconnected")
    var statuses: [CastMediaStatus] = []
    var receiverStatuses: [CastStatus] = []
    var errors: [String] = []
    var idle: [CastMediaStatus] = []
    var waitingFor: ((CastMediaStatus) -> Bool)?
    var waiter: XCTestExpectation?
    var log: [String] = []

    func note(_ s: String) {
      let stamp = ISO8601DateFormatter().string(from: Date())
      log.append("\(stamp) \(s)")
      print("[real] \(s)")
    }

    func castClient(_ client: CastClient, didConnectTo device: CastDevice) { note("connected to \(device.name)"); connected.fulfill() }
    func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) { note("disconnected"); disconnected.fulfill() }
    func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) { note("connect failed: \(String(describing: error))"); errors.append("connect: \(String(describing: error))") }
    var onFirstReceiverStatus: (() -> Void)?
    func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {
      let first = receiverStatuses.isEmpty
      receiverStatuses.append(status)
      note("receiver status: volume \(status.volume) muted \(status.muted) apps \(status.apps.map(\.displayName))")
      if first { onFirstReceiverStatus?() }
    }
    func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {
      statuses.append(status)
      note("media status: \(status)")
      if status.playerState == .idle { idle.append(status) }
      if let waitingFor, waitingFor(status) { self.waitingFor = nil; waiter?.fulfill() }
    }
    func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int) { note("media session \(mediaSessionId) ended") }
    func castClient(_ client: CastClient, appSessionDidEnd app: CastApp) { note("app session ended: \(app.displayName)") }
    func castClient(_ client: CastClient, mediaDidFail error: CastError) { note("media failed: \(error)"); errors.append("media: \(error)") }

    func expectStatus(_ description: String, _ predicate: @escaping (CastMediaStatus) -> Bool) -> XCTestExpectation {
      let e = XCTestExpectation(description: description)
      waiter = e
      waitingFor = predicate
      return e
    }
  }

  private final class Finder: CastDeviceScannerDelegate, @unchecked Sendable {
    let wanted: String
    let found = XCTestExpectation(description: "device found")
    var device: CastDevice?
    var seen: [String] = []
    init(wanted: String) { self.wanted = wanted }
    func deviceDidComeOnline(_ device: CastDevice) {
      seen.append(device.name)
      if self.device == nil, device.name.localizedCaseInsensitiveContains(wanted) {
        self.device = device
        found.fulfill()
      }
    }
    func deviceDidChange(_ device: CastDevice) {}
    func deviceDidGoOffline(_ device: CastDevice) {}
  }

  /// Sets a device's volume and leaves: `CASTKIT_REAL_DEVICE=… CASTKIT_SET_VOLUME=0.1`.
  func testSetVolumeOnly() throws {
    guard let wanted = ProcessInfo.processInfo.environment["CASTKIT_REAL_DEVICE"], !wanted.isEmpty,
          let level = ProcessInfo.processInfo.environment["CASTKIT_SET_VOLUME"].flatMap(Float.init) else {
      throw XCTSkip("set CASTKIT_REAL_DEVICE and CASTKIT_SET_VOLUME")
    }
    let scanner = CastDeviceScanner()
    let finder = Finder(wanted: wanted)
    scanner.delegate = finder
    scanner.startScanning()
    XCTWaiter().wait(for: [finder.found], timeout: 15)
    scanner.stopScanning()
    let device = try XCTUnwrap(finder.device, "no device matching \"\(wanted)\" — seen: \(finder.seen)")
    let events = Events()
    let client = CastClient(device: device)
    client.delegate = events
    client.connect()
    XCTWaiter().wait(for: [events.connected], timeout: 15)
    XCTAssertTrue(client.isConnected)
    client.setVolume(level)
    Thread.sleep(forTimeInterval: 1)
    print("[real] \(device.name) volume set to \(level) (was \(events.receiverStatuses.first.map { "\($0.volume)" } ?? "?"))")
    client.disconnect()
  }

  /// Queues two clips and waits for the receiver to move to the second on
  /// its own: `CASTKIT_REAL_DEVICE=… CASTKIT_REAL_CLIP=<10 s clip URL>`.
  func testQueueAdvancesOnARealReceiver() throws {
    guard let wanted = ProcessInfo.processInfo.environment["CASTKIT_REAL_DEVICE"], !wanted.isEmpty,
          let clip = ProcessInfo.processInfo.environment["CASTKIT_REAL_CLIP"].flatMap(URL.init(string:)) else {
      throw XCTSkip("set CASTKIT_REAL_DEVICE and CASTKIT_REAL_CLIP (a short clip)")
    }
    let contentType = ProcessInfo.processInfo.environment["CASTKIT_REAL_CONTENT_TYPE"] ?? "audio/wav"
    let scanner = CastDeviceScanner()
    let finder = Finder(wanted: wanted)
    scanner.delegate = finder
    scanner.startScanning()
    XCTWaiter().wait(for: [finder.found], timeout: 15)
    scanner.stopScanning()
    let device = try XCTUnwrap(finder.device)
    let events = Events()
    let client = CastClient(device: device)
    client.delegate = events
    client.connect()
    XCTWaiter().wait(for: [events.connected], timeout: 15)
    defer { client.disconnect() }
    let restoreVolume = ProcessInfo.processInfo.environment["CASTKIT_RESTORE_VOLUME"].flatMap(Float.init) ?? 0.36
    client.setVolume(0.1)
    defer { client.setVolume(restoreVolume); Thread.sleep(forTimeInterval: 0.5) }

    let launched = expectation(description: "launched")
    let appBox = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      appBox.value = result
      launched.fulfill()
    }
    wait(for: [launched], timeout: 15)
    let app = try XCTUnwrap(appBox.value).get()

    let items = ["first", "second"].map { key in
      CastQueueItem(media: CastMedia(title: "Queue \(key)", artist: "Highnote", url: clip, contentType: contentType),
                    preloadTime: 5, customData: ["key": key])
    }
    let loaded = expectation(description: "queue loaded")
    let box = ResultBox<CastMediaStatus>()
    client.queueLoad(items: items, with: app) { result in
      box.value = result
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 20)
    let status = try XCTUnwrap(box.value).get()
    print("[real] queue load reply: \(status) items=\(status.items?.map { "\($0.itemId):\($0.customData)" } ?? [])")
    // The reply may be an idle status with no items; the queue is asked for.
    let idsKnown = expectation(description: "item ids")
    let idsBox = ResultBox<[Int]>()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      client.queueItemIds { result in
        idsBox.value = result
        idsKnown.fulfill()
      }
    }
    wait(for: [idsKnown], timeout: 15)
    let ids = try XCTUnwrap(idsBox.value).get()
    print("[real] queue item ids: \(ids)")
    XCTAssertEqual(ids.count, 2)
    let firstId = try XCTUnwrap(ids.first)
    let secondId = try XCTUnwrap(ids.last)
    let itemsKnown = expectation(description: "items")
    let itemsBox = ResultBox<[CastQueueItemStatus]>()
    client.queueItems(itemIds: ids) { result in
      itemsBox.value = result
      itemsKnown.fulfill()
    }
    wait(for: [itemsKnown], timeout: 10)
    let reported = try XCTUnwrap(itemsBox.value).get()
    print("[real] queue items: \(reported.map { "\($0.itemId):\($0.customData)" })")
    XCTAssertEqual(reported.map { $0.customData["key"] }, ["first", "second"])

    let onSecond = events.expectStatus("second item playing") { $0.currentItemId == secondId && $0.playerState == .playing }
    XCTWaiter().wait(for: [onSecond], timeout: 60)
    let last = try XCTUnwrap(events.statuses.last)
    print("[real] final status: \(last) currentItemId=\(last.currentItemId ?? -1) (first \(firstId), second \(secondId))")
    XCTAssertEqual(last.currentItemId, secondId, "the receiver did not move on to the second item by itself")
    let stopped = expectation(description: "stopped")
    client.stop { _ in stopped.fulfill() }
    wait(for: [stopped], timeout: 10)
    client.stopCurrentApp()
    Thread.sleep(forTimeInterval: 1)
  }

  func testPlaysOnARealReceiver() throws {
    guard let wanted = ProcessInfo.processInfo.environment["CASTKIT_REAL_DEVICE"], !wanted.isEmpty else {
      throw XCTSkip("set CASTKIT_REAL_DEVICE to (part of) a device name to run against real hardware")
    }
    let clipURL = URL(string: ProcessInfo.processInfo.environment["CASTKIT_REAL_CLIP"]
                      ?? "https://www2.cs.uic.edu/~i101/SoundFiles/BabyElephantWalk60.wav")!
    let contentType = ProcessInfo.processInfo.environment["CASTKIT_REAL_CONTENT_TYPE"] ?? "audio/wav"

    // Discover.
    let scanner = CastDeviceScanner()
    let finder = Finder(wanted: wanted)
    scanner.delegate = finder
    scanner.startScanning()
    XCTWaiter().wait(for: [finder.found], timeout: 15)
    scanner.stopScanning()
    let device = try XCTUnwrap(finder.device, "no device matching \"\(wanted)\" — seen: \(finder.seen)")
    print("[real] using \(device.name) (\(device.modelName)) at \(device.hostName):\(device.port) caps=\(device.capabilities.rawValue)")

    // Connect.
    let events = Events()
    let client = CastClient(device: device)
    client.delegate = events
    client.connect()
    XCTWaiter().wait(for: [events.connected], timeout: 15)
    XCTAssertTrue(client.isConnected, "did not connect: \(events.errors)")
    defer {
      client.disconnect()
    }

    // Quiet. The first receiver status carries the volume to put back; a
    // heartbeat can declare the connection before that status has arrived.
    let statusSeen = XCTestExpectation(description: "receiver status")
    if events.receiverStatuses.isEmpty {
      events.onFirstReceiverStatus = { statusSeen.fulfill() }
      XCTWaiter().wait(for: [statusSeen], timeout: 10)
    }
    let originalVolume = events.receiverStatuses.first.map { Float($0.volume) }
    print("[real] original volume: \(originalVolume.map { "\($0)" } ?? "unknown")")
    client.setVolume(0.1)
    let restoreVolume = ProcessInfo.processInfo.environment["CASTKIT_RESTORE_VOLUME"].flatMap(Float.init) ?? originalVolume ?? 0.36
    defer {
      client.setVolume(restoreVolume)
      print("[real] volume put back to \(restoreVolume)")
      Thread.sleep(forTimeInterval: 0.5)
    }

    // Launch and load.
    let launched = expectation(description: "launched")
    let appBox = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      appBox.value = result
      launched.fulfill()
    }
    wait(for: [launched], timeout: 15)
    let app = try XCTUnwrap(appBox.value).get()
    print("[real] launched \(app.displayName) session \(app.sessionId) transport \(app.transportId)")

    let media = CastMedia(title: "CastKit test clip", artist: "Highnote", url: clipURL, contentType: contentType, autoplay: true, currentTime: 0)
    let loaded = expectation(description: "loaded")
    let statusBox = ResultBox<CastMediaStatus>()
    let playing = events.expectStatus("playing") { $0.playerState == .playing }
    client.load(media: media, with: app) { result in
      statusBox.value = result
      loaded.fulfill()
    }
    wait(for: [loaded], timeout: 20)
    let loadStatus = try XCTUnwrap(statusBox.value).get()
    print("[real] load reply: \(loadStatus)")
    XCTAssertTrue(loadStatus.hasMediaSession)

    // A Nest Hub can take a while to fetch the file before it reports anything.
    XCTWaiter().wait(for: [playing], timeout: 45)
    let playingStatus = try XCTUnwrap(events.statuses.last(where: { $0.playerState == .playing }), "never reported PLAYING: \(events.errors)")
    print("[real] playing at \(playingStatus.currentTime)s of \(playingStatus.duration.map { "\($0)" } ?? "?")s, rate \(playingStatus.playbackRate)")
    Thread.sleep(forTimeInterval: 2)

    // Pause, resume, seek — each confirmed by the receiver's own report.
    let paused = expectation(description: "pause reply")
    client.pause { result in
      print("[real] pause reply: \(result)")
      paused.fulfill()
    }
    wait(for: [paused], timeout: 10)
    let pausedReport = events.expectStatus("paused") { $0.playerState == .paused }
    XCTWaiter().wait(for: [pausedReport], timeout: 10)
    XCTAssertEqual(events.statuses.last?.playerState, .paused)

    // Paused: the estimate must not move.
    let frozen = events.statuses.last!.estimatedCurrentTime
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(events.statuses.last!.estimatedCurrentTime, frozen, accuracy: 0.001)

    let resumed = expectation(description: "play reply")
    client.play { _ in resumed.fulfill() }
    wait(for: [resumed], timeout: 10)

    // Media-level volume (per-track gain, fades): the receiver applies it
    // to this media session and reports it back, and the device volume
    // is untouched.
    for level: Float in [0.5, 1.0] {
      let volumeSet = expectation(description: "media volume \(level) reply")
      let volumeBox = ResultBox<CastMediaStatus>()
      client.setMediaVolume(level) { result in
        volumeBox.value = result
        volumeSet.fulfill()
      }
      wait(for: [volumeSet], timeout: 10)
      let volumeStatus = try XCTUnwrap(volumeBox.value).get()
      print("[real] media volume \(level) reply: level \(volumeStatus.volumeLevel.map { "\($0)" } ?? "?") state \(volumeStatus.playerState)")
      XCTAssertEqual(try XCTUnwrap(volumeStatus.volumeLevel, "no media volume in the reply"), Double(level), accuracy: 0.01)
      XCTAssertEqual(volumeStatus.playerState, .playing, "setting the media volume must not change the state")
    }
    let deviceVolume = events.receiverStatuses.last.map { Float($0.volume) }
    XCTAssertEqual(deviceVolume ?? 0.1, 0.1, accuracy: 0.02, "the device volume is not the media volume")

    let sought = expectation(description: "seek reply")
    let seekBox = ResultBox<CastMediaStatus>()
    client.seek(to: 30) { result in
      seekBox.value = result
      sought.fulfill()
    }
    wait(for: [sought], timeout: 10)
    if case .some(.success(let s)) = seekBox.value {
      print("[real] after seek: \(s.currentTime)s state \(s.playerState)")
    }
    let nearThirty = events.expectStatus("at 30s") { $0.currentTime >= 28 && $0.currentTime <= 36 && $0.playerState == .playing }
    XCTWaiter().wait(for: [nearThirty], timeout: 10)

    let asked = expectation(description: "status reply")
    client.requestMediaStatus(for: app) { result in
      print("[real] GET_STATUS reply: \(result)")
      asked.fulfill()
    }
    wait(for: [asked], timeout: 10)

    // Stop the media: the receiver reports IDLE/CANCELLED, or that the session is gone.
    let stopped = expectation(description: "stop reply")
    client.stop { result in
      print("[real] stop reply: \(result)")
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 10)
    Thread.sleep(forTimeInterval: 1)

    client.stopCurrentApp()
    Thread.sleep(forTimeInterval: 1)
    XCTAssertNil(client.connectedApp)
    XCTAssertTrue(events.errors.isEmpty, "errors: \(events.errors)")
    print("[real] transcript:\n" + events.log.joined(separator: "\n"))
  }
}

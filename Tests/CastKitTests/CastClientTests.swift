import XCTest
@testable import CastKit

/// Records what the client tells its delegate.
final class RecordingDelegate: CastClientDelegate, @unchecked Sendable {
  let connected = XCTestExpectation(description: "connected")
  let disconnected = XCTestExpectation(description: "disconnected")
  let failed = XCTestExpectation(description: "failed")
  let appSessionEnded = XCTestExpectation(description: "app session ended")
  let mediaSessionEnded = XCTestExpectation(description: "media session ended")
  let mediaFailed = XCTestExpectation(description: "media failed")
  var mediaStatuses: [CastMediaStatus] = []
  var lastError: Error?

  func castClient(_ client: CastClient, didConnectTo device: CastDevice) { connected.fulfill() }
  func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) { disconnected.fulfill() }
  func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {
    lastError = error
    failed.fulfill()
  }
  func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) { mediaStatuses.append(status) }
  func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int) { mediaSessionEnded.fulfill() }
  func castClient(_ client: CastClient, appSessionDidEnd app: CastApp) { appSessionEnded.fulfill() }
  func castClient(_ client: CastClient, mediaDidFail error: CastError) {
    lastError = error
    mediaFailed.fulfill()
  }
}

final class CastClientTests: XCTestCase {
  var receiver: FakeReceiver!
  var client: CastClient!
  var delegate: RecordingDelegate!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    delegate = RecordingDelegate()
    client = CastClient(device: receiver.device)
    client.usesTLS = false
    client.delegate = delegate
  }

  override func tearDown() {
    client.delegate = nil
    client.disconnect()
    receiver.stop()
    client = nil
    receiver = nil
    delegate = nil
  }

  private func connect() {
    client.connect()
    wait(for: [delegate.connected], timeout: 5)
  }

  /// Launches the receiver app and returns it.
  private func launch() throws -> CastApp {
    let done = expectation(description: "launched")
    let box = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return try XCTUnwrap(box.value).get()
  }

  private func media() -> CastMedia {
    CastMedia(title: "Song", artist: "Artist", url: URL(string: "http://example.test/a.mp3")!, contentType: "audio/mpeg")
  }

  // MARK: - Connecting

  func testConnectsOnceTheReceiverAnswers() {
    connect()
    XCTAssertTrue(client.isConnected)
    // The client introduced itself and asked for status, in that order.
    let types = receiver.received.map(\.type)
    XCTAssertEqual(types.first, "CONNECT")
    XCTAssertTrue(types.contains("GET_STATUS"))
    XCTAssertTrue(types.contains("PING"))
  }

  func testSilentReceiverIsNotConnected() {
    // The socket opens, but nothing ever comes back.
    receiver.speaks = false
    client.connectTimeout = 1
    delegate.connected.isInverted = true
    client.connect()
    wait(for: [delegate.failed], timeout: 5)
    wait(for: [delegate.connected], timeout: 0.5)
    XCTAssertFalse(client.isConnected)
    guard case .some(.timeout) = delegate.lastError as? CastError else {
      return XCTFail("expected a timeout, got \(String(describing: delegate.lastError))")
    }
  }

  func testRefusedConnectionFails() {
    receiver.stop()   // nothing listens on the port any more
    client.connectTimeout = 3
    client.connect()
    wait(for: [delegate.failed], timeout: 5)
    XCTAssertFalse(client.isConnected)
  }

  func testReceiverClosingTheSocketDisconnects() {
    connect()
    receiver.dropConnection()
    wait(for: [delegate.disconnected], timeout: 5)
    XCTAssertFalse(client.isConnected)
  }

  func testCloseFromReceiverDisconnects() {
    connect()
    receiver.push(namespace: CastNamespace.connection, payload: ["type": "CLOSE"], from: "receiver-0")
    wait(for: [delegate.disconnected], timeout: 5)
    XCTAssertFalse(client.isConnected)
  }

  func testCanReconnectAfterDisconnect() {
    connect()
    client.disconnect()
    wait(for: [delegate.disconnected], timeout: 5)
    let again = RecordingDelegate()
    client.delegate = again
    client.connect()
    wait(for: [again.connected], timeout: 5)
    XCTAssertTrue(client.isConnected)
    XCTAssertGreaterThanOrEqual(receiver.received.filter { $0.type == "CONNECT" }.count, 2)
  }

  // MARK: - Requests and replies

  func testLoadFailureReachesTheCaller() throws {
    connect()
    let app = try launch()
    receiver.overrides["LOAD"] = { _ in [(CastNamespace.media, ["type": "LOAD_FAILED", "detailedErrorCode": 104])] }
    let done = expectation(description: "load answered")
    let box = ResultBox<CastMediaStatus>()
    client.load(media: media(), with: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    guard case .some(.failure(.rejected(let type, _))) = box.value else {
      return XCTFail("expected a rejection, got \(String(describing: box.value))")
    }
    XCTAssertEqual(type, "LOAD_FAILED")
  }

  func testLoadSuccessCarriesTheNewSession() throws {
    connect()
    let app = try launch()
    let done = expectation(description: "load answered")
    let box = ResultBox<CastMediaStatus>()
    client.load(media: media(), with: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    let status = try XCTUnwrap(box.value).get()
    XCTAssertEqual(status.mediaSessionId, 7)
    XCTAssertEqual(status.playerState, .buffering)
    XCTAssertEqual(status.duration, 240.5)
  }

  func testMediaStatusRequestParsesTheSession() throws {
    connect()
    let app = try launch()
    let done = expectation(description: "status answered")
    let box = ResultBox<CastMediaStatus>()
    client.requestMediaStatus(for: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    let status = try XCTUnwrap(box.value).get()
    XCTAssertEqual(status.mediaSessionId, 7, "the session comes from status[0], not the envelope")
    XCTAssertEqual(status.playerState, .playing)
  }

  func testInvalidRequestReachesTheCaller() throws {
    connect()
    let app = try launch()
    receiver.overrides["GET_STATUS"] = { message in
      guard message.namespace == CastNamespace.media else {
        return [(CastNamespace.receiver, ["type": "RECEIVER_STATUS", "status": ["volume": ["level": 0.5]]])]
      }
      return [(CastNamespace.media, ["type": "INVALID_REQUEST", "reason": "INVALID_MEDIA_SESSION_ID"])]
    }
    let done = expectation(description: "answered")
    let box = ResultBox<CastMediaStatus>()
    client.requestMediaStatus(for: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    guard case .some(.failure(.rejected("INVALID_REQUEST", "INVALID_MEDIA_SESSION_ID"))) = box.value else {
      return XCTFail("expected INVALID_REQUEST, got \(String(describing: box.value))")
    }
  }

  func testPendingRequestFailsOnDisconnect() throws {
    connect()
    let app = try launch()
    receiver.speaks = false
    let done = expectation(description: "answered")
    let box = ResultBox<CastMediaStatus>()
    client.load(media: media(), with: app) { result in
      box.value = result
      done.fulfill()
    }
    client.disconnect()
    wait(for: [done], timeout: 5)
    guard case .some(.failure(.disconnected)) = box.value else {
      return XCTFail("expected .disconnected, got \(String(describing: box.value))")
    }
  }

  func testUnknownNamespaceDoesNotStallTheBatch() throws {
    connect()
    let app = try launch()
    // A message on a namespace the client never registered, followed by
    // the real reply — in one write, so they land in one read.
    receiver.overrides["GET_STATUS"] = { message in
      guard message.namespace == CastNamespace.media else {
        return [(CastNamespace.receiver, ["type": "RECEIVER_STATUS", "status": ["volume": ["level": 0.5]]])]
      }
      return [
        ("urn:x-cast:com.google.cast.cac", ["type": "SOMETHING", "requestId": 0]),
        (CastNamespace.media, ["type": "MEDIA_STATUS", "status": [["mediaSessionId": 9, "playerState": "PLAYING", "currentTime": 3, "playbackRate": 1]]]),
      ]
    }
    let done = expectation(description: "answered")
    let box = ResultBox<CastMediaStatus>()
    client.requestMediaStatus(for: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get().mediaSessionId, 9)
  }

  // MARK: - Session events

  func testEmptyStatusEndsTheMediaSession() throws {
    connect()
    _ = try launch()
    receiver.push(namespace: CastNamespace.media, payload: ["type": "MEDIA_STATUS", "status": []])
    wait(for: [delegate.mediaSessionEnded], timeout: 5)
    XCTAssertNil(client.currentMediaStatus)
  }

  func testAppCloseEndsTheAppSession() throws {
    connect()
    let app = try launch()
    receiver.push(namespace: CastNamespace.connection, payload: ["type": "CLOSE"], from: app.transportId)
    wait(for: [delegate.appSessionEnded], timeout: 5)
    XCTAssertNil(client.connectedApp)
    XCTAssertTrue(client.isConnected, "the device connection stays up")
  }

  func testAppMissingFromReceiverStatusEndsTheAppSession() throws {
    connect()
    _ = try launch()
    receiver.appRunning = false
    receiver.push(namespace: CastNamespace.receiver, payload: receiver.receiverStatus())
    wait(for: [delegate.appSessionEnded], timeout: 5)
    XCTAssertNil(client.connectedApp)
  }

  func testUnsolicitedMediaErrorIsReported() throws {
    connect()
    _ = try launch()
    receiver.push(namespace: CastNamespace.media, payload: ["type": "ERROR", "reason": "PLAYBACK_FAILED"])
    wait(for: [delegate.mediaFailed], timeout: 5)
  }

  func testStopCurrentAppStopsOurs() throws {
    connect()
    _ = try launch()
    client.stopCurrentApp()
    let stop = expectation(description: "STOP sent")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { stop.fulfill() }
    wait(for: [stop], timeout: 2)
    let stops = receiver.received.filter { $0.type == "STOP" && $0.namespace == CastNamespace.receiver }
    XCTAssertEqual(stops.count, 1)
    XCTAssertEqual(stops.first?.json["sessionId"] as? String, "session-1")
    XCTAssertNil(client.connectedApp)
  }

  // MARK: - Status model

  func testEstimatedTimeOnlyAdvancesWhilePlaying() {
    let playing = CastMediaStatus(json: JSON(["mediaSessionId": 1, "playerState": "PLAYING", "currentTime": 10.0, "playbackRate": 1.0, "media": ["duration": 12.0]]))
    let paused = CastMediaStatus(json: JSON(["mediaSessionId": 1, "playerState": "PAUSED", "currentTime": 10.0, "playbackRate": 1.0]))
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertGreaterThan(playing.estimatedCurrentTime, 10.2)
    XCTAssertLessThanOrEqual(playing.estimatedCurrentTime, 12.0, "capped at the duration")
    XCTAssertEqual(paused.estimatedCurrentTime, 10.0)
  }

  func testIdleReasonParses() {
    let finished = CastMediaStatus(json: JSON(["mediaSessionId": 1, "playerState": "IDLE", "idleReason": "FINISHED"]))
    XCTAssertEqual(finished.idleReason, .finished)
    XCTAssertFalse(CastMediaStatus(json: JSON(["playerState": "IDLE"])).hasMediaSession)
  }
}

/// A box for a result handed to a closure from another thread.
final class ResultBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<T, CastError>?
  var value: Result<T, CastError>? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

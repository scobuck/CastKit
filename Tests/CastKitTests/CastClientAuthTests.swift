import XCTest
@testable import CastKit

/// Device authentication in the connection itself, against the fake
/// receiver over plain TCP: the client is told to treat a fixture as the
/// receiver's TLS certificate and to trust the fixture root.
final class CastClientAuthTests: XCTestCase {
  var receiver: FakeReceiver!
  var client: CastClient!
  var delegate: RecordingDelegate!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    delegate = RecordingDelegate()
    client = CastClient(device: receiver.device)
    client.usesTLS = false
    client.testPeerCertificate = AuthFixtures.data("tls")
    client.deviceAuthenticator = AuthFixtures.authenticator()
    client.authenticationTime = { AuthFixtures.now }
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

  /// Answers challenges as a genuine (fixture) device would, signing over `tls`.
  private func answer(signingOver tls: String = "tls", chain: [String] = ["device", "ica"]) {
    receiver.authReply = { challenge in
      guard let message = try? Extensions_Api_CastChannel_DeviceAuthMessage(serializedBytes: challenge) else { return nil }
      return AuthFixtures.reply(nonce: message.challenge.senderNonce, chain: chain, tls: tls)
    }
  }

  private func expectAuthenticationFailure(file: StaticString = #filePath, line: UInt = #line) {
    wait(for: [delegate.failed], timeout: 5)
    XCTAssertFalse(client.isConnected, file: file, line: line)
    guard case .some(.deviceAuthenticationFailed) = delegate.lastError as? CastError else {
      return XCTFail("expected deviceAuthenticationFailed, got \(String(describing: delegate.lastError))", file: file, line: line)
    }
  }

  func testAGenuineReceiverIsAuthenticatedBeforeAnythingElse() throws {
    answer()
    client.connect()
    wait(for: [delegate.connected], timeout: 5)
    XCTAssertTrue(client.isConnected)
    XCTAssertEqual(client.deviceAuthentication?.rootName, "CastKit Test Root CA")

    let received = receiver.received
    // The challenge came first, platform to platform, with a fresh nonce and SHA-256.
    let first = try XCTUnwrap(received.first)
    XCTAssertEqual(first.namespace, CastNamespace.auth)
    XCTAssertEqual(first.sourceId, "sender-0")
    XCTAssertEqual(first.destinationId, "receiver-0")
    let challenge = try Extensions_Api_CastChannel_DeviceAuthMessage(serializedBytes: try XCTUnwrap(first.binary))
    XCTAssertEqual(challenge.challenge.senderNonce.count, 16)
    XCTAssertEqual(challenge.challenge.hashAlgorithm, .sha256)
    // Then the ordinary introduction.
    XCTAssertEqual(received.dropFirst().first?.type, "CONNECT")
    XCTAssertEqual(received.filter { $0.namespace == CastNamespace.auth }.count, 1)
  }

  func testEachConnectionGetsAFreshNonce() throws {
    answer()
    client.connect()
    wait(for: [delegate.connected], timeout: 5)
    client.disconnect()
    wait(for: [delegate.disconnected], timeout: 5)
    let again = RecordingDelegate()
    client.delegate = again
    client.connect()
    wait(for: [again.connected], timeout: 5)
    let nonces = try receiver.received.filter { $0.namespace == CastNamespace.auth }.map {
      try Extensions_Api_CastChannel_DeviceAuthMessage(serializedBytes: XCTUnwrap($0.binary)).challenge.senderNonce
    }
    XCTAssertEqual(nonces.count, 2)
    XCTAssertNotEqual(nonces[0], nonces[1])
  }

  func testAnImpostorGetsNothingButTheChallenge() throws {
    // A genuine device's signature, but over another TLS certificate: what a
    // relay in the middle would have to offer.
    answer(signingOver: "tls-other")
    client.connect()
    expectAuthenticationFailure()

    // Nothing after the challenge: no CONNECT, GET_STATUS or PING.
    XCTAssertEqual(receiver.received.map(\.namespace), [CastNamespace.auth])

    // And nothing later either: every call says "not connected".
    let launched = expectation(description: "launch answered")
    let box = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      box.value = result
      launched.fulfill()
    }
    wait(for: [launched], timeout: 5)
    guard case .some(.failure(.notConnected)) = box.value else {
      return XCTFail("expected notConnected, got \(String(describing: box.value))")
    }
    client.setVolume(0.9)
    _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 0.3)
    XCTAssertEqual(receiver.received.map(\.namespace), [CastNamespace.auth])
  }

  func testAnUntrustedChainIsRefused() {
    answer(chain: ["other-device", "other-ica"])
    client.connect()
    expectAuthenticationFailure()
    XCTAssertEqual(receiver.received.count, 1)
  }

  func testAReceiverThatSpeaksBeforeAnsweringIsRefused() {
    // A plain receiver that knows nothing of device auth: it sends its status
    // unasked. Chromium treats any message before the reply as an error.
    receiver.authReply = { [receiver] _ in
      receiver?.push(namespace: CastNamespace.receiver, payload: ["type": "RECEIVER_STATUS", "status": [:] as [String: Any]])
      return nil
    }
    client.connect()
    expectAuthenticationFailure()
    XCTAssertEqual(receiver.received.count, 1)
  }

  func testAnAuthErrorIsRefused() {
    receiver.authReply = { _ in
      var message = Extensions_Api_CastChannel_DeviceAuthMessage()
      message.error.errorType = .internalError
      return try? message.serializedBytes()
    }
    client.connect()
    expectAuthenticationFailure()
    guard case .some(.deviceAuthenticationFailed(let reason)) = delegate.lastError as? CastError else { return }
    XCTAssertTrue(reason.contains("INTERNAL_ERROR"), reason)
  }

  func testASilentReceiverTimesOutWithNothingSent() {
    receiver.authReply = { _ in nil }
    client.connectTimeout = 1
    client.connect()
    wait(for: [delegate.failed], timeout: 5)
    guard case .some(.timeout) = delegate.lastError as? CastError else {
      return XCTFail("expected a timeout, got \(String(describing: delegate.lastError))")
    }
    XCTAssertEqual(receiver.received.map(\.namespace), [CastNamespace.auth])
  }

  func testCallsDuringAuthenticationAreRefused() {
    // The reply is slow; a LOAD asked for meanwhile must not go out.
    receiver.authReply = { challenge in
      Thread.sleep(forTimeInterval: 0.6)
      guard let message = try? Extensions_Api_CastChannel_DeviceAuthMessage(serializedBytes: challenge) else { return nil }
      return AuthFixtures.reply(nonce: message.challenge.senderNonce)
    }
    client.connect()
    _ = XCTWaiter().wait(for: [XCTestExpectation(description: "challenge out")], timeout: 0.3)
    XCTAssertEqual(receiver.received.map(\.namespace), [CastNamespace.auth])
    let app = CastApp(json: JSON(["appId": CastAppIdentifier.defaultMediaPlayer, "sessionId": "s", "transportId": "t"]))
    let refused = expectation(description: "load refused")
    let box = ResultBox<CastMediaStatus>()
    client.load(media: CastMedia(title: "t", url: URL(string: "http://example.test/a.mp3")!, contentType: "audio/mpeg"),
                with: app) { result in
      box.value = result
      refused.fulfill()
    }
    wait(for: [refused], timeout: 5)
    guard case .some(.failure(.notConnected)) = box.value else {
      return XCTFail("expected notConnected, got \(String(describing: box.value))")
    }
    wait(for: [delegate.connected], timeout: 5)
    XCTAssertFalse(receiver.received.contains { $0.type == "LOAD" })
  }

  func testAuthenticationOnlyStopsAfterTheReply() {
    answer()
    let done = expectation(description: "outcome")
    let box = ResultBox<CastDeviceAuthResult>()
    client.authenticationOnly = { result in
      box.value = result
      done.fulfill()
    }
    delegate.connected.isInverted = true
    client.connect()
    wait(for: [done], timeout: 5)
    wait(for: [delegate.connected], timeout: 0.5)
    XCTAssertEqual(try box.value?.get().rootName, "CastKit Test Root CA")
    XCTAssertEqual(receiver.received.map(\.namespace), [CastNamespace.auth])
  }
}

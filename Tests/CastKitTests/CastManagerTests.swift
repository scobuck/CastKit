import XCTest
@testable import CastKit

/// CastManager against the fake receiver: what it keeps between the
/// receiver's reports, and what it must let go of.
@MainActor
final class CastManagerTests: XCTestCase {
  var receiver: FakeReceiver!
  var manager: CastManager!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    manager = CastManager()
    manager.usesTLS = false
    let connected = expectation(description: "connected")
    manager.onCastConnected = { connected.fulfill() }
    manager.connect(to: receiver.device)
    wait(for: [connected], timeout: 5)
  }

  override func tearDown() {
    manager.disconnect()
    receiver.stop()
  }

  private func item(_ key: String) -> CastQueueItem {
    CastQueueItem(media: CastMedia(title: key, url: URL(string: "http://example.test/\(key).mp3")!, contentType: "audio/mpeg"),
                  customData: ["key": key])
  }

  /// Loads a queue and waits until the manager is on its first item.
  private func loadQueue(_ keys: [String]) {
    let onFirst = expectation(description: "on the first item")
    onFirst.assertForOverFulfill = false
    manager.onCastItemChanged = { _, _ in onFirst.fulfill() }
    manager.loadQueue(keys.map(item))
    wait(for: [onFirst], timeout: 5)
    manager.onCastItemChanged = nil
  }

  /// Pushes a status of the fake's current state and waits for the manager
  /// to have taken in that one — told apart from the replies the manager
  /// asks for on its own by its position.
  private func pushStatus(_ state: String, currentTime: Double) {
    let applied = expectation(description: "status at \(currentTime)s applied")
    applied.assertForOverFulfill = false
    manager.onCastPositionUpdated = { position in
      if abs(position - currentTime) < 0.5 { applied.fulfill() }
    }
    receiver.push(namespace: CastNamespace.media, payload: receiver.mediaStatus(state: state, currentTime: currentTime))
    wait(for: [applied], timeout: 5)
    manager.onCastPositionUpdated = nil
  }

  /// The receiver's reported length is per item. Once it moves to the next
  /// queue item, the last item's length must not be passed off as this
  /// one's — a Nest Hub can play a whole item without ever reporting a
  /// length, so the stale one would stand for the entire track.
  func testReportedLengthIsForgottenWhenTheReceiverMovesOn() throws {
    loadQueue(["a", "b"])
    XCTAssertEqual(manager.mediaDuration ?? -1, 240.5, accuracy: 0.001, "the load reply's length")
    let secondId = try XCTUnwrap(manager.queueItemIds.last)
    XCTAssertNotEqual(secondId, manager.currentItemId)

    // The receiver moves on without saying how long the next item is. (The
    // length goes first: the manager may ask for a status at any moment,
    // and a reply in between must not carry the change with the old length.)
    receiver.mediaDuration = nil
    receiver.queueCurrentId = secondId
    let onSecond = expectation(description: "on the second item")
    manager.onCastItemChanged = { _, _ in onSecond.fulfill() }
    pushStatus("BUFFERING", currentTime: 42)
    wait(for: [onSecond], timeout: 5)
    XCTAssertEqual(manager.currentItemId, secondId)
    XCTAssertNil(manager.mediaDuration, "the previous item's length was reported for the next one")

    // Once it does report the item's length, that is the length.
    receiver.mediaDuration = 180
    pushStatus("PLAYING", currentTime: 43)
    XCTAssertEqual(manager.mediaDuration ?? -1, 180, accuracy: 0.001)
  }

  /// A new media session on the same item — the receiver replaced what it
  /// plays — is a new length too.
  func testReportedLengthIsForgottenWithTheMediaSession() throws {
    loadQueue(["a"])
    XCTAssertEqual(manager.mediaDuration ?? -1, 240.5, accuracy: 0.001)

    receiver.mediaDuration = nil
    receiver.mediaSessionId = 8
    pushStatus("PLAYING", currentTime: 44)
    XCTAssertNil(manager.mediaDuration)
  }

  // MARK: Suspended in the background

  /// Leaving the app leaves the receiver playing: the session is suspended, not ended, and
  /// coming back rejoins the same receiver session where it is (iOS suspends a backgrounded
  /// app, and its connection with it; that used to end the cast).
  func testASuspendedSessionLeavesTheReceiverPlayingAndResumes() throws {
    loadQueue(["a"])
    var ended = false
    manager.onCastEnded = { _ in ended = true }
    let suspended = expectation(description: "suspended")
    manager.onCastSuspended = { suspended.fulfill() }
    manager.suspend()
    wait(for: [suspended], timeout: 5)
    XCTAssertFalse(manager.isConnected)
    XCTAssertNotNil(manager.suspendedSession)
    XCTAssertTrue(receiver.appRunning, "the receiver plays on")
    XCTAssertFalse(ended)

    let resumed = expectation(description: "resumed")
    var resumedStatus: CastMediaStatus?
    manager.onCastConnected = { XCTFail("a resume isn't a new connection") }
    manager.onCastResumed = { status in resumedStatus = status; resumed.fulfill() }
    manager.resume()
    wait(for: [resumed], timeout: 5)
    XCTAssertTrue(manager.isConnected)
    XCTAssertNil(manager.suspendedSession)
    XCTAssertNotNil(resumedStatus, "the receiver's media as it is now")
    XCTAssertFalse(ended)
  }

  /// Back after the receiver was stopped (from the TV, idled out): the session ends.
  func testResumingAfterTheReceiverStoppedEndsTheSession() throws {
    loadQueue(["a"])
    let suspended = expectation(description: "suspended")
    manager.onCastSuspended = { suspended.fulfill() }
    manager.suspend()
    wait(for: [suspended], timeout: 5)
    receiver.appRunning = false

    let ended = expectation(description: "ended")
    manager.onCastResumed = { _ in XCTFail("nothing to rejoin") }
    manager.onCastEnded = { _ in ended.fulfill() }
    manager.resume()
    wait(for: [ended], timeout: 5)
    XCTAssertFalse(manager.isConnected)
    XCTAssertNotNil(manager.endReason)
  }

  // MARK: Joining another sender's session

  /// Another sender's session: the receiver app running with media it loaded.
  private func anotherSenderIsPlaying() {
    receiver.appRunning = true
    receiver.mediaContentId = "http://example.test/film.m3u8"
    receiver.mediaCustomData = ["highframeItem": "42", "highframeLoad": "L1"]
  }

  /// A second device joins what the first is playing: nothing launched or loaded, the media
  /// and its custom data as the receiver has them.
  func testJoiningAnotherSendersSessionLoadsNothing() throws {
    anotherSenderIsPlaying()
    let other = CastManager()
    other.usesTLS = false
    defer { other.disconnect() }
    let joined = expectation(description: "joined")
    var joinedStatus: CastMediaStatus?
    other.onCastConnected = { XCTFail("a join isn't a new connection") }
    other.onCastJoined = { status in joinedStatus = status; joined.fulfill() }
    let before = receiver.received.count
    other.join(receiver.device)
    wait(for: [joined], timeout: 5)
    XCTAssertTrue(other.isConnected)
    XCTAssertEqual(joinedStatus?.mediaCustomData?["highframeItem"], "42")
    XCTAssertEqual(other.mediaContentID, "http://example.test/film.m3u8")
    XCTAssertEqual(other.mediaCustomData?["highframeLoad"], "L1")
    let sent = receiver.received.dropFirst(before).map(\.type)
    XCTAssertFalse(sent.contains("LAUNCH"), "nothing launched: \(sent)")
    XCTAssertFalse(sent.contains("LOAD"), "nothing loaded: \(sent)")
  }

  /// Nothing of this app running there: the join ends the session.
  func testJoiningWithNothingRunningEndsTheSession() throws {
    receiver.appRunning = false
    let other = CastManager()
    other.usesTLS = false
    defer { other.disconnect() }
    let ended = expectation(description: "ended")
    var reason: CastError?
    other.onCastJoined = { _ in XCTFail("nothing to join") }
    other.onCastError = { reason = $0; ended.fulfill() }
    other.join(receiver.device)
    wait(for: [ended], timeout: 5)
    XCTAssertFalse(other.isConnected)
    if case .session? = reason {} else { XCTFail("ended with \(String(describing: reason))") }
  }

  /// Another sender loading something else shows as a new media session with its content and
  /// custom data, the last one's forgotten.
  func testAnotherSendersLoadShowsAsNewMedia() throws {
    manager.load(CastMedia(url: URL(string: "http://example.test/mine.m3u8")!, contentType: "application/x-mpegurl",
                           metadata: .generic(title: "Mine"), customData: ["highframeLoad": "mine"]))
    let mine = expectation(description: "mine reported")
    mine.assertForOverFulfill = false
    manager.onCastPositionUpdated = { [manager] _ in if manager?.mediaCustomData?["highframeLoad"] == "mine" { mine.fulfill() } }
    receiver.push(namespace: CastNamespace.media, payload: receiver.mediaStatus(state: "PLAYING", currentTime: 3))
    wait(for: [mine], timeout: 5)
    let firstSession = manager.mediaSessionId
    XCTAssertEqual(manager.mediaContentID, "http://example.test/mine.m3u8")

    receiver.mediaSessionId = 8
    receiver.mediaContentId = "http://example.test/theirs.m3u8"
    receiver.mediaCustomData = ["highframeLoad": "theirs"]
    let theirs = expectation(description: "theirs reported")
    theirs.assertForOverFulfill = false
    manager.onCastPositionUpdated = { [manager] _ in if manager?.mediaCustomData?["highframeLoad"] == "theirs" { theirs.fulfill() } }
    receiver.push(namespace: CastNamespace.media, payload: receiver.mediaStatus(state: "PLAYING", currentTime: 1))
    wait(for: [theirs], timeout: 5)
    XCTAssertNotEqual(manager.mediaSessionId, firstSession)
    XCTAssertEqual(manager.mediaContentID, "http://example.test/theirs.m3u8")
  }

  /// Leaving a joined session closes the connection and leaves the receiver playing.
  func testLeavingAJoinedSessionLeavesTheReceiverPlaying() throws {
    anotherSenderIsPlaying()
    let other = CastManager()
    other.usesTLS = false
    let joined = expectation(description: "joined")
    other.onCastJoined = { _ in joined.fulfill() }
    other.join(receiver.device)
    wait(for: [joined], timeout: 5)
    let ended = expectation(description: "ended")
    other.onCastEnded = { _ in ended.fulfill() }
    other.leave()
    wait(for: [ended], timeout: 5)
    XCTAssertFalse(other.isConnected)
    XCTAssertTrue(receiver.appRunning, "the receiver plays on")
    XCTAssertFalse(receiver.received.contains { $0.namespace == CastNamespace.receiver && $0.type == "STOP" })
  }
}


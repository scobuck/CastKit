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
}

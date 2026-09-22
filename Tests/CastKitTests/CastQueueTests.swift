import XCTest
@testable import CastKit

final class CastQueueTests: XCTestCase {
  var receiver: FakeReceiver!
  var client: CastClient!
  var delegate: RecordingDelegate!
  var app: CastApp!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    delegate = RecordingDelegate()
    client = CastClient(device: receiver.device)
    client.usesTLS = false
    client.delegate = delegate
    client.connect()
    wait(for: [delegate.connected], timeout: 5)
    let launched = expectation(description: "launched")
    let box = ResultBox<CastApp>()
    client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { result in
      box.value = result
      launched.fulfill()
    }
    wait(for: [launched], timeout: 5)
    app = try XCTUnwrap(box.value).get()
  }

  override func tearDown() {
    client.delegate = nil
    client.disconnect()
    receiver.stop()
  }

  private func item(_ key: String) -> CastQueueItem {
    CastQueueItem(media: CastMedia(title: key, url: URL(string: "http://example.test/\(key).mp3")!, contentType: "audio/mpeg"),
                  customData: ["key": key])
  }

  private func queueLoad(_ keys: [String], startIndex: Int = 0) throws -> CastMediaStatus {
    let done = expectation(description: "queue loaded")
    let box = ResultBox<CastMediaStatus>()
    client.queueLoad(items: keys.map(item), startIndex: startIndex, with: app) { result in
      box.value = result
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return try XCTUnwrap(box.value).get()
  }

  func testQueueLoadReportsItemsAndTheCurrentOne() throws {
    let status = try queueLoad(["a", "b", "c"], startIndex: 1)
    XCTAssertEqual(status.items?.map(\.customData["key"]), ["a", "b", "c"])
    XCTAssertEqual(status.currentItemId, status.items?[1].itemId)
    XCTAssertEqual(receiver.received.last(where: { $0.type == "QUEUE_LOAD" })?.json["startIndex"] as? Int, 1)
  }

  func testInsertAndRemove() throws {
    let status = try queueLoad(["a", "b"])
    let bId = try XCTUnwrap(status.items?[1].itemId)
    let inserted = expectation(description: "inserted")
    let box = ResultBox<CastMediaStatus>()
    client.queueInsert(items: [item("x")], insertBefore: bId) { result in
      box.value = result
      inserted.fulfill()
    }
    wait(for: [inserted], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get().items?.map(\.customData["key"]), ["a", "x", "b"])

    let removed = expectation(description: "removed")
    let box2 = ResultBox<CastMediaStatus>()
    client.queueRemove(itemIds: [bId]) { result in
      box2.value = result
      removed.fulfill()
    }
    wait(for: [removed], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box2.value).get().items?.map(\.customData["key"]), ["a", "x"])
  }

  func testJumpMovesTheCurrentItem() throws {
    let status = try queueLoad(["a", "b", "c"])
    let jumped = expectation(description: "jumped")
    let box = ResultBox<CastMediaStatus>()
    client.queueJump(1) { result in
      box.value = result
      jumped.fulfill()
    }
    wait(for: [jumped], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get().currentItemId, status.items?[1].itemId)
  }

  func testItemIds() throws {
    let status = try queueLoad(["a", "b"])
    let answered = expectation(description: "ids")
    let box = ResultBox<[Int]>()
    client.queueItemIds { result in
      box.value = result
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
    XCTAssertEqual(try XCTUnwrap(box.value).get(), status.items?.map(\.itemId))
  }

  func testQueueChangeBroadcastReachesTheDelegate() throws {
    _ = try queueLoad(["a"])
    let changed = expectation(description: "queue changed")
    let recorder = QueueRecorder(expectation: changed)
    client.delegate = recorder
    receiver.push(namespace: CastNamespace.media, payload: ["type": "QUEUE_CHANGE", "itemIds": [1, 2, 3], "changeType": "INSERT"])
    wait(for: [changed], timeout: 5)
    XCTAssertEqual(recorder.itemIds, [1, 2, 3])
  }

  private final class QueueRecorder: CastClientDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    var itemIds: [Int] = []
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func castClient(_ client: CastClient, queueChanged itemIds: [Int], changeType: String) {
      self.itemIds = itemIds
      expectation.fulfill()
    }
  }
}

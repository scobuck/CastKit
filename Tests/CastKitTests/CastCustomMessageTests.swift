import XCTest
@testable import CastKit

/// An app's own receiver: launched without loading anything, asked on the app's namespace,
/// and what it reports it is showing.
@MainActor
final class CastCustomMessageTests: XCTestCase {
  let namespace = "urn:x-cast:com.example.test"
  var receiver: FakeReceiver!
  var manager: CastManager!

  override func setUpWithError() throws {
    receiver = try FakeReceiver()
    try receiver.start()
    manager = CastManager()
    manager.usesTLS = false
    manager.registerNamespace(namespace)
    let connected = expectation(description: "connected")
    manager.onCastConnected = { connected.fulfill() }
    manager.connect(to: receiver.device)
    wait(for: [connected], timeout: 5)
  }

  override func tearDown() {
    manager.disconnect()
    receiver.stop()
  }

  private func launch() {
    let launched = expectation(description: "launched")
    manager.launchApp { result in
      if case .failure(let error) = result { XCTFail("launch failed: \(error)") }
      launched.fulfill()
    }
    wait(for: [launched], timeout: 5)
  }

  func testAQuestionOnTheAppsNamespaceGetsItsAnswer() throws {
    let namespace = self.namespace
    receiver.overrides["CAPABILITIES"] = { message in
      guard message.namespace == namespace else { return [] }
      return [(namespace, ["type": "CAPABILITIES", "hevc": true, "maxHeight": 2160])]
    }
    launch()
    let answered = expectation(description: "answered")
    manager.sendMessage(["type": "CAPABILITIES"], namespace: namespace) { result in
      switch result {
      case .success(let text):
        let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(json?["hevc"] as? Bool, true)
        XCTAssertEqual(json?["maxHeight"] as? Int, 2160)
      case .failure(let error):
        XCTFail("no answer: \(error)")
      }
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
    let sent = try XCTUnwrap(receiver.received.last(where: { $0.namespace == namespace }))
    XCTAssertEqual(sent.destinationId, "app-transport-1", "addressed to the launched app")
  }

  func testTheAppsOwnMessagesArriveUnasked() {
    launch()
    let heard = expectation(description: "heard")
    manager.onCustomMessage = { namespace, text in
      XCTAssertEqual(namespace, self.namespace)
      XCTAssertTrue(text.contains("HELLO"))
      heard.fulfill()
    }
    receiver.push(namespace: namespace, payload: ["type": "HELLO"], from: "app-transport-1")
    wait(for: [heard], timeout: 5)
  }

  func testASendBeforeLaunchingSaysNotConnected() {
    let refused = expectation(description: "refused")
    manager.sendMessage(["type": "CAPABILITIES"], namespace: namespace) { result in
      if case .failure(.notConnected) = result { refused.fulfill() }
    }
    wait(for: [refused], timeout: 2)
  }

  func testWhatTheReceiverShowsIsReported() {
    launch()
    let applied = expectation(description: "applied")
    applied.assertForOverFulfill = false
    manager.onCastPositionUpdated = { _ in
      if self.manager.videoInfo?.hdrType == "dv" { applied.fulfill() }
    }
    var status = receiver.mediaStatus(state: "PLAYING", currentTime: 3)
    if var entries = status["status"] as? [[String: Any]] {
      entries[0]["videoInfo"] = ["width": 3840, "height": 2160, "hdrType": "dv"]
      status["status"] = entries
    }
    receiver.push(namespace: CastNamespace.media, payload: status)
    wait(for: [applied], timeout: 5)
    XCTAssertEqual(manager.videoInfo, CastVideoInfo(width: 3840, height: 2160, hdrType: "dv"))
  }
}

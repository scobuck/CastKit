import Foundation
import Network
import SwiftProtobuf
@testable import CastKit

/// A Cast receiver on the loopback interface, speaking CASTV2 over plain
/// TCP, that answers with whatever the test scripts. It stands in for a
/// Chromecast so the client's handling of replies, rejections, closes and
/// silence can be exercised without a device.
final class FakeReceiver: @unchecked Sendable {
  typealias Message = Extensions_Api_CastChannel_CastMessage

  /// A message the receiver got, decoded.
  struct Received: @unchecked Sendable {
    let namespace: String
    let sourceId: String
    let destinationId: String
    let json: [String: Any]

    var type: String { json["type"] as? String ?? "" }
    var requestId: Int { json["requestId"] as? Int ?? 0 }
  }

  /// Decides the replies to a message. Returns (namespace, payload)
  /// pairs; the request id is filled in from the request unless given.
  typealias Script = @Sendable (Received) -> [(String, [String: Any])]

  let listener: NWListener
  private(set) var port: UInt16 = 0
  private let queue = DispatchQueue(label: "FakeReceiver")
  private var connection: NWConnection?
  private var buffer = Data()
  private let lock = NSLock()
  private var receivedMessages: [Received] = []
  private var script: Script
  private let appTransportId = "app-transport-1"

  /// Whether the receiver reports a running Default Media Receiver.
  var appRunning = false
  /// The default reply behaviour, which tests override per message type.
  var overrides: [String: Script] = [:]
  /// When false, the receiver accepts the socket and says nothing at all.
  var speaks = true
  /// The media-level volume last set on the fake.
  private(set) var mediaVolume: Double = 1
  /// The receiver's queue: (itemId, customData) in order, and the current one.
  private(set) var queueItems: [(id: Int, custom: [String: String])] = []
  private(set) var queueCurrentId: Int?
  private var nextItemId = 1

  var received: [Received] {
    lock.withLock { receivedMessages }
  }

  init() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    listener = try NWListener(using: params, on: .any)
    script = { _ in [] }
    script = { [weak self] message in self?.defaultReplies(for: message) ?? [] }
  }

  func start() throws {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state, let port = self?.listener.port?.rawValue {
        self?.port = port
        ready.signal()
      }
      if case .failed = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
      throw NSError(domain: "FakeReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
    }
  }

  func stop() {
    connection?.cancel()
    connection = nil
    listener.cancel()
  }

  /// Closes the socket from the receiver's side.
  func dropConnection() {
    queue.async { [self] in
      connection?.cancel()
      connection = nil
    }
  }

  /// A device the client can be pointed at.
  var device: CastDevice {
    CastDevice(id: "fake", name: "Fake Receiver", modelName: "Test", hostName: "127.0.0.1",
               ipAddress: "127.0.0.1", port: Int(port), capabilitiesMask: 4, status: "", iconPath: "")
  }

  // MARK: - Sending

  /// Sends an unsolicited message to the client.
  func push(namespace: String, payload: [String: Any], from sourceId: String? = nil) {
    queue.async { [self] in
      send(namespace: namespace, payload: payload, sourceId: sourceId ?? (namespace == CastNamespace.media ? appTransportId : "receiver-0"), destinationId: "*")
    }
  }

  private func send(namespace: String, payload: [String: Any], sourceId: String, destinationId: String) {
    guard let connection else { return }
    var message = Message()
    message.protocolVersion = .castv210
    message.sourceID = sourceId
    message.destinationID = destinationId
    message.namespace = namespace
    message.payloadType = .string
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: json, encoding: .utf8),
          let body = try? { message.payloadUtf8 = text; return try message.serializedData() }() else { return }
    var length = UInt32(body.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(body)
    connection.send(content: frame, completion: .idempotent)
  }

  // MARK: - Receiving

  private func accept(_ connection: NWConnection) {
    self.connection?.cancel()
    self.connection = connection
    buffer.removeAll()
    connection.stateUpdateHandler = { _ in }
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data { self.buffer.append(data); self.drain() }
      if isComplete || error != nil { return }
      self.receive(on: connection)
    }
  }

  private func drain() {
    while buffer.count >= 4 {
      let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
      guard buffer.count >= 4 + length else { return }
      let body = buffer.subdata(in: 4..<(4 + length))
      buffer.removeSubrange(0..<(4 + length))
      guard let message = try? Message(serializedData: body),
            let json = try? JSONSerialization.jsonObject(with: Data(message.payloadUtf8.utf8)) as? [String: Any] else { continue }
      let received = Received(namespace: message.namespace, sourceId: message.sourceID, destinationId: message.destinationID, json: json)
      lock.withLock { receivedMessages.append(received) }
      guard speaks else { continue }
      let replies = overrides[received.type].map { $0(received) } ?? script(received)
      for (namespace, var payload) in replies {
        if payload["requestId"] == nil, received.requestId != 0 { payload["requestId"] = received.requestId }
        let source = namespace == CastNamespace.media ? appTransportId : "receiver-0"
        send(namespace: namespace, payload: payload, sourceId: source, destinationId: message.sourceID)
      }
    }
  }

  // MARK: - Default behaviour of a Default Media Receiver

  func receiverStatus(requestId: Int? = nil) -> [String: Any] {
    var status: [String: Any] = ["volume": ["level": 0.5, "muted": false, "controlType": "attenuation"]]
    if appRunning {
      status["applications"] = [[
        "appId": CastAppIdentifier.defaultMediaPlayer,
        "displayName": "Default Media Receiver",
        "sessionId": "session-1",
        "transportId": appTransportId,
        "statusText": "Ready To Cast",
        "isIdleScreen": false,
        "namespaces": [["name": CastNamespace.media]],
      ]]
    }
    var payload: [String: Any] = ["type": "RECEIVER_STATUS", "status": status]
    if let requestId { payload["requestId"] = requestId }
    return payload
  }

  func mediaStatus(state: String = "PLAYING", currentTime: Double = 1.5, idleReason: String? = nil, sessionId: Int = 7, requestId: Int? = nil, withQueue: Bool = false) -> [String: Any] {
    var entry: [String: Any] = [
      "mediaSessionId": sessionId,
      "playbackRate": 1,
      "playerState": state,
      "currentTime": currentTime,
      "supportedMediaCommands": 15,
      "volume": ["level": mediaVolume, "muted": false],
      "media": ["contentId": "http://example.test/a.mp3", "contentType": "audio/mpeg", "streamType": "BUFFERED", "duration": 240.5],
    ]
    if let idleReason { entry["idleReason"] = idleReason }
    if let current = queueCurrentId {
      entry["currentItemId"] = current
      if withQueue {
        entry["items"] = queueItems.map { ["itemId": $0.id, "customData": $0.custom, "media": ["contentId": "http://example.test/\($0.id).mp3", "contentType": "audio/mpeg", "streamType": "BUFFERED"]] as [String: Any] }
      }
    }
    var payload: [String: Any] = ["type": "MEDIA_STATUS", "status": [entry]]
    if let requestId { payload["requestId"] = requestId }
    return payload
  }

  private func defaultReplies(for message: Received) -> [(String, [String: Any])] {
    switch (message.namespace, message.type) {
    case (CastNamespace.heartbeat, "PING"):
      return [(CastNamespace.heartbeat, ["type": "PONG"])]
    case (CastNamespace.receiver, "GET_STATUS"):
      return [(CastNamespace.receiver, receiverStatus())]
    case (CastNamespace.receiver, "LAUNCH"):
      appRunning = true
      return [(CastNamespace.receiver, receiverStatus())]
    case (CastNamespace.receiver, "STOP"):
      appRunning = false
      return [(CastNamespace.receiver, receiverStatus())]
    case (CastNamespace.media, "LOAD"):
      queueItems = []; queueCurrentId = nil
      return [(CastNamespace.media, mediaStatus(state: "BUFFERING", currentTime: 0))]
    case (CastNamespace.media, "QUEUE_LOAD"):
      let items = (message.json["items"] as? [[String: Any]]) ?? []
      queueItems = items.map { item in
        defer { nextItemId += 1 }
        return (nextItemId, (item["customData"] as? [String: String]) ?? [:])
      }
      let start = (message.json["startIndex"] as? Int) ?? 0
      queueCurrentId = queueItems.indices.contains(start) ? queueItems[start].id : queueItems.first?.id
      return [(CastNamespace.media, mediaStatus(state: "BUFFERING", currentTime: 0, withQueue: true))]
    case (CastNamespace.media, "QUEUE_INSERT"):
      let items = (message.json["items"] as? [[String: Any]]) ?? []
      let added = items.map { item -> (id: Int, custom: [String: String]) in
        defer { nextItemId += 1 }
        return (nextItemId, (item["customData"] as? [String: String]) ?? [:])
      }
      if let before = message.json["insertBefore"] as? Int, let index = queueItems.firstIndex(where: { $0.id == before }) {
        queueItems.insert(contentsOf: added, at: index)
      } else {
        queueItems.append(contentsOf: added)
      }
      return [(CastNamespace.media, mediaStatus(withQueue: true))]
    case (CastNamespace.media, "QUEUE_REMOVE"):
      let ids = Set((message.json["itemIds"] as? [Int]) ?? [])
      queueItems.removeAll { ids.contains($0.id) }
      return [(CastNamespace.media, mediaStatus(withQueue: true))]
    case (CastNamespace.media, "QUEUE_UPDATE"):
      if let jump = message.json["jump"] as? Int, let current = queueCurrentId,
         let index = queueItems.firstIndex(where: { $0.id == current }) {
        let target = index + jump
        if queueItems.indices.contains(target) { queueCurrentId = queueItems[target].id }
      }
      return [(CastNamespace.media, mediaStatus(withQueue: true))]
    case (CastNamespace.media, "QUEUE_GET_ITEM_IDS"):
      return [(CastNamespace.media, ["type": "QUEUE_ITEM_IDS", "itemIds": queueItems.map(\.id)])]
    case (CastNamespace.media, "SET_VOLUME"):
      if let level = (message.json["volume"] as? [String: Any])?["level"] as? Double { mediaVolume = level }
      return [(CastNamespace.media, mediaStatus())]
    case (CastNamespace.media, "GET_STATUS"), (CastNamespace.media, "PAUSE"), (CastNamespace.media, "PLAY"), (CastNamespace.media, "SEEK"):
      return [(CastNamespace.media, mediaStatus(state: message.type == "PAUSE" ? "PAUSED" : "PLAYING"))]
    default:
      return []
    }
  }
}

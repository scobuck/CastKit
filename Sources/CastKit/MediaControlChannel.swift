import Foundation
// SwiftyJSON is vendored in the same module

class MediaControlChannel: CastChannel {
  typealias StatusCompletion = @Sendable (Result<CastMediaStatus, CastError>) -> Void

  private var delegate: MediaControlChannelDelegate? {
    return requestDispatcher as? MediaControlChannelDelegate
  }

  init() {
    super.init(namespace: CastNamespace.media)
  }

  override func handleResponse(_ json: JSON, sourceId: String) {
    guard let rawType = json[CastJSONPayloadKeys.type].string else { return }

    guard let type = CastMessageType(rawValue: rawType) else {
      #if DEBUG
      print("[CastKit] media: unknown message type \(rawType)")
      #endif
      return
    }

    switch type {
    case .mediaStatus:
      if let status = json[CastJSONPayloadKeys.status].array?.first {
        delegate?.channel(self, didReceive: CastMediaStatus(json: status))
      } else {
        // An empty status list is the receiver saying there is no media
        // session any more — the media ended or was stopped. It used to
        // be dropped, and commands went on carrying the dead session id.
        delegate?.channelDidReportNoMediaSession(self)
      }

    case .queueChange:
      delegate?.channel(self, queueChanged: json[CastJSONPayloadKeys.itemIds].array?.compactMap(\.int) ?? [],
                        changeType: json[CastJSONPayloadKeys.changeType].string ?? "")

    case _ where type.isError:
      // A rejection carrying a request id reaches that request's handler
      // (see `mediaStatus(from:)`); one without is the receiver reporting
      // on its own — a stream that died mid-play, say.
      guard (json[CastJSONPayloadKeys.requestId].int ?? 0) == 0 else { return }
      delegate?.channel(self, didReceiveError: .rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string))

    default:
      break
    }
  }

  /// Reads a reply as a media status, or as the receiver's rejection. Every
  /// reply used to be taken for a status, so LOAD_FAILED and
  /// INVALID_REQUEST left their callers waiting for an answer that had
  /// already arrived.
  static func mediaStatus(from json: JSON) -> Result<CastMediaStatus, CastError> {
    let rawType = json[CastJSONPayloadKeys.type].string ?? ""
    guard CastMessageType(rawValue: rawType) == .mediaStatus else {
      return .failure(.rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string))
    }
    guard let status = json[CastJSONPayloadKeys.status].array?.first else {
      return .failure(.session("No media session"))
    }
    return .success(CastMediaStatus(json: status))
  }

  private func send(_ request: CastRequest, completion: StatusCompletion?) {
    guard let completion else {
      send(request)
      return
    }
    send(request) { result in
      switch result {
      case .success(let json):
        completion(Self.mediaStatus(from: json))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func requestMediaStatus(for app: CastApp, completion: StatusCompletion? = nil) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.statusRequest.rawValue,
      CastJSONPayloadKeys.sessionId: app.sessionId
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: app.transportId,
                                       payload: payload)
    send(request, completion: completion)
  }

  public func sendPause(for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    send(.pause, for: app, mediaSessionId: mediaSessionId, completion: completion)
  }

  public func sendPlay(for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    send(.play, for: app, mediaSessionId: mediaSessionId, completion: completion)
  }

  public func sendStop(for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    send(.stop, for: app, mediaSessionId: mediaSessionId, completion: completion)
  }

  public func sendSeek(to currentTime: Float, for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.seek.rawValue,
      CastJSONPayloadKeys.sessionId: app.sessionId,
      CastJSONPayloadKeys.currentTime: currentTime,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: app.transportId,
                                 payload: payload)
    send(request, completion: completion)
  }

  private func send(_ message: CastMessageType, for app: CastApp, mediaSessionId: Int, completion: StatusCompletion?) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: message.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: app.transportId,
                                 payload: payload)
    send(request, completion: completion)
  }

  // MARK: Queue

  public func queueLoad(items: [CastQueueItem], startIndex: Int, startTime: Double, repeatMode: String, with app: CastApp, completion: @escaping StatusCompletion) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueLoad.rawValue,
      CastJSONPayloadKeys.sessionId: app.sessionId,
      CastJSONPayloadKeys.items: items.map(\.dict),
      CastJSONPayloadKeys.startIndex: startIndex,
      CastJSONPayloadKeys.currentTime: startTime,
      CastJSONPayloadKeys.repeatMode: repeatMode
    ]
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request, completion: completion)
  }

  public func queueInsert(items: [CastQueueItem], insertBefore: Int?, for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    var payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueInsert.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId,
      CastJSONPayloadKeys.items: items.map(\.dict)
    ]
    if let insertBefore { payload[CastJSONPayloadKeys.insertBefore] = insertBefore }
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request, completion: completion)
  }

  public func queueRemove(itemIds: [Int], for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueRemove.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId,
      CastJSONPayloadKeys.itemIds: itemIds
    ]
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request, completion: completion)
  }

  /// Jumps `jump` items (±1 for next/previous) or to `currentItemId`.
  public func queueUpdate(jump: Int?, currentItemId: Int?, repeatMode: String?, for app: CastApp, mediaSessionId: Int, completion: StatusCompletion? = nil) {
    var payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueUpdate.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId
    ]
    if let jump { payload[CastJSONPayloadKeys.jump] = jump }
    if let currentItemId { payload[CastJSONPayloadKeys.currentItemId] = currentItemId }
    if let repeatMode { payload[CastJSONPayloadKeys.repeatMode] = repeatMode }
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request, completion: completion)
  }

  /// The receiver's items in full — custom data included — for the ids given.
  public func queueItems(itemIds: [Int], for app: CastApp, mediaSessionId: Int, completion: @escaping @Sendable (Result<[CastQueueItemStatus], CastError>) -> Void) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueGetItems.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId,
      CastJSONPayloadKeys.itemIds: itemIds
    ]
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request) { result in
      switch result {
      case .success(let json):
        let rawType = json[CastJSONPayloadKeys.type].string ?? ""
        if CastMessageType(rawValue: rawType) == .queueItems {
          completion(.success(json[CastJSONPayloadKeys.items].array?.map(CastQueueItemStatus.init) ?? []))
        } else {
          completion(.failure(.rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string)))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func queueItemIds(for app: CastApp, mediaSessionId: Int, completion: @escaping @Sendable (Result<[Int], CastError>) -> Void) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.queueGetItemIds.rawValue,
      CastJSONPayloadKeys.mediaSessionId: mediaSessionId
    ]
    let request = requestDispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    send(request) { result in
      switch result {
      case .success(let json):
        let rawType = json[CastJSONPayloadKeys.type].string ?? ""
        if CastMessageType(rawValue: rawType) == .queueItemIds {
          completion(.success(json[CastJSONPayloadKeys.itemIds].array?.compactMap(\.int) ?? []))
        } else {
          completion(.failure(.rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string)))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func load(media: CastMedia, with app: CastApp, completion: @escaping StatusCompletion) {
    var payload = media.dict
    payload[CastJSONPayloadKeys.type] = CastMessageType.load.rawValue
    payload[CastJSONPayloadKeys.sessionId] = app.sessionId

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: app.transportId,
                                       payload: payload)
    send(request, completion: completion)
  }
}

protocol MediaControlChannelDelegate: AnyObject {
  func channel(_ channel: MediaControlChannel, didReceive mediaStatus: CastMediaStatus)
  func channelDidReportNoMediaSession(_ channel: MediaControlChannel)
  func channel(_ channel: MediaControlChannel, didReceiveError error: CastError)
  func channel(_ channel: MediaControlChannel, queueChanged itemIds: [Int], changeType: String)
}

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
}

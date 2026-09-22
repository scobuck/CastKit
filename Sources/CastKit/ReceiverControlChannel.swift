import Foundation
// SwiftyJSON is vendored in the same module

class ReceiverControlChannel: CastChannel {
  override weak var requestDispatcher: RequestDispatchable! {
    didSet {
      if requestDispatcher != nil {
        requestStatus()
      }
    }
  }

  private var delegate: ReceiverControlChannelDelegate? {
    return requestDispatcher as? ReceiverControlChannelDelegate
  }

  init() {
    super.init(namespace: CastNamespace.receiver)
  }

  override func handleResponse(_ json: JSON, sourceId: String) {
    guard let rawType = json[CastJSONPayloadKeys.type].string else { return }

    guard let type = CastMessageType(rawValue: rawType) else {
      #if DEBUG
      print("[CastKit] receiver: unknown message type \(rawType)")
      #endif
      return
    }

    switch type {
    case .status:
      delegate?.channel(self, didReceive: CastStatus(json: json))

    default:
      break
    }
  }

  /// Reads a reply as a receiver status, or as the receiver's rejection.
  static func receiverStatus(from json: JSON) -> Result<CastStatus, CastError> {
    let rawType = json[CastJSONPayloadKeys.type].string ?? ""
    guard CastMessageType(rawValue: rawType) == .status else {
      return .failure(.rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string))
    }
    return .success(CastStatus(json: json))
  }

  public func getAppAvailability(apps: [CastApp], completion: @escaping @Sendable (Result<AppAvailability, CastError>) -> Void) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.availableApps.rawValue,
      CastJSONPayloadKeys.appId: apps.map { $0.id }
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request) { result in
      switch result {
      case .success(let json):
        let rawType = json[CastJSONPayloadKeys.type].string ?? ""
        if let type = CastMessageType(rawValue: rawType), type.isError {
          completion(.failure(.rejected(type: rawType, reason: json[CastJSONPayloadKeys.reason].string)))
        } else {
          completion(.success(AppAvailability(json: json)))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func requestStatus(completion: (@Sendable (Result<CastStatus, CastError>) -> Void)? = nil) {
    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: [CastJSONPayloadKeys.type: CastMessageType.statusRequest.rawValue])

    if let completion = completion {
      send(request) { result in
        switch result {
        case .success(let json):
          completion(Self.receiverStatus(from: json))

        case .failure(let error):
          completion(.failure(error))
        }
      }
    } else {
      send(request)
    }
  }

  func launch(appId: String, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.launch.rawValue,
      CastJSONPayloadKeys.appId: appId
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request) { result in
      switch result {
      case .success(let json):
        switch Self.receiverStatus(from: json) {
        case .success(let status):
          // The one we asked for, not whatever happens to be listed first.
          guard let app = status.apps.first(where: { $0.id == appId }) ?? status.apps.first else {
            completion(.failure(CastError.launch("Unable to get launched app instance")))
            return
          }
          completion(.success(app))
        case .failure(let error):
          completion(.failure(error))
        }

      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func stop(app: CastApp) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.stop.rawValue,
      CastJSONPayloadKeys.sessionId: app.sessionId
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request)
  }

  public func setVolume(_ volume: Float) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.setVolume.rawValue,
      CastJSONPayloadKeys.volume: [CastJSONPayloadKeys.level: volume]
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: CastConstants.receiver,
                                 payload: payload)

    send(request)
  }

  public func setMuted(_ isMuted: Bool) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.setVolume.rawValue,
      CastJSONPayloadKeys.volume: [CastJSONPayloadKeys.muted: isMuted]
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: CastConstants.receiver,
                                 payload: payload)

    send(request)
  }
}

protocol ReceiverControlChannelDelegate: RequestDispatchable {
  func channel(_ channel: ReceiverControlChannel, didReceive status: CastStatus)
}

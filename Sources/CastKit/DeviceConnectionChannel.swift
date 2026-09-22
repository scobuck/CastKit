import Foundation
// SwiftyJSON is vendored in the same module

class DeviceConnectionChannel: CastChannel {
  override weak var requestDispatcher: RequestDispatchable! {
    didSet {
      if requestDispatcher != nil {
        connect()
      }
    }
  }

  private var delegate: DeviceConnectionChannelDelegate? {
    return requestDispatcher as? DeviceConnectionChannelDelegate
  }

  init() {
    super.init(namespace: CastNamespace.connection)
  }

  /// The receiver sends CLOSE on this namespace when it drops the virtual
  /// connection: from `receiver-0` when it is done with the sender, from an
  /// app's transport when that app quits or another sender takes over. It
  /// used to be dropped, so the app kept a dead transport id and every
  /// later request timed out.
  override func handleResponse(_ json: JSON, sourceId: String) {
    guard json[CastJSONPayloadKeys.type].string == CastMessageType.close.rawValue else { return }
    delegate?.channel(self, didReceiveCloseFrom: sourceId)
  }

  func connect() {
    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: CastConstants.receiver,
                                 payload: [CastJSONPayloadKeys.type: CastMessageType.connect.rawValue])

    send(request)
  }

  func connect(to app: CastApp) {
    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: app.transportId,
                                 payload: [CastJSONPayloadKeys.type: CastMessageType.connect.rawValue])

    send(request)
  }

  public func leave(_ app: CastApp) {
    let request = requestDispatcher.request(withNamespace: namespace,
                                 destinationId: app.transportId,
                                 payload: [CastJSONPayloadKeys.type: CastMessageType.close.rawValue])

    send(request)
  }
}

protocol DeviceConnectionChannelDelegate: AnyObject {
  func channel(_ channel: DeviceConnectionChannel, didReceiveCloseFrom sourceId: String)
}

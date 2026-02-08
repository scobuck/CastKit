import Foundation

class DeviceSetupChannel: CastChannel {
  init() {
    super.init(namespace: CastNamespace.setup)
  }

  public func requestDeviceConfig() {
    let params = [
      "version",
      "name",
      "build_info.cast_build_revision",
      "net.ip_address",
      "net.online",
      "net.ssid",
      "wifi.signal_level",
      "wifi.noise_level"
    ]

    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.getDeviceConfig.rawValue,
      "params": params,
      "data": [String: Any]()
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request) { result in
      switch result {
      case .success(let json):
        print(json)

      case .failure(let error):
        print(error)
      }
    }
  }

  public func requestSetDeviceConfig() {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.getDeviceConfig.rawValue,
      "data": [String: Any]()
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request) { result in
      switch result {
      case .success(let json):
        print(json)

      case .failure(let error):
        print(error)
      }
    }
  }

  public func requestAppDeviceId(app: CastApp) {
    let payload: [String: Any] = [
      CastJSONPayloadKeys.type: CastMessageType.getAppDeviceId.rawValue,
      "data": ["app_id": app.id]
    ]

    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: payload)

    send(request) { result in
      switch result {
      case .success(let json):
        print(json)

      case .failure(let error):
        print(error)
      }
    }
  }
}

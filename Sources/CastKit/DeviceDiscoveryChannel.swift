import Foundation

class DeviceDiscoveryChannel: CastChannel {
  init() {
    super.init(namespace: CastNamespace.discovery)
  }

  func requestDeviceInfo() {
    let request = requestDispatcher.request(withNamespace: namespace,
                                       destinationId: CastConstants.receiver,
                                       payload: [CastJSONPayloadKeys.type: CastMessageType.getDeviceInfo.rawValue])

    send(request) { result in
      switch result {
      case .success(let json):
        #if DEBUG
        print(json)
        #endif

      case .failure(let error):
        #if DEBUG
        print(error)
        #endif
      }
    }
  }
}

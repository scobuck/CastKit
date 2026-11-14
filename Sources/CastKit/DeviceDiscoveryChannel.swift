import Foundation
import os

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
      case .success:
        Log.channel.debug("device info: reply received")
      case .failure(let error):
        Log.channel.debug("device info: \(error.description, privacy: .public)")
      }
    }
  }
}

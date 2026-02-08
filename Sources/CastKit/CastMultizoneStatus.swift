import Foundation
// SwiftyJSON is vendored in the same module

public class CastMultizoneStatus: @unchecked Sendable {
  public let devices: [CastMultizoneDevice]

  public init(devices: [CastMultizoneDevice]) {
    self.devices = devices
  }
}

extension CastMultizoneStatus {

  convenience init(json: JSON) {
    let status = json[CastJSONPayloadKeys.status]
    let devices = status[CastJSONPayloadKeys.devices].array?.map(CastMultizoneDevice.init) ?? []

    self.init(devices: devices)
  }

}

import Foundation
// SwiftyJSON is vendored in the same module

public final class CastStatus: NSObject, @unchecked Sendable {

    public var volume: Double = 1
    public var muted: Bool = false
    public var apps: [CastApp] = []

    public override var description: String {
        return "CastStatus(volume: \(volume), muted: \(muted), apps: \(apps))"
    }

}

extension CastStatus {

    convenience init(json: JSON) {
        self.init()
        let status = json[CastJSONPayloadKeys.status]
        let volume = status[CastJSONPayloadKeys.volume]

        if let volume = volume[CastJSONPayloadKeys.level].double {
            self.volume = volume
        }
        if let muted = volume[CastJSONPayloadKeys.muted].bool {
            self.muted = muted
        }

        if let apps = status[CastJSONPayloadKeys.applications].array {
          self.apps = apps.compactMap(CastApp.init)
        }
    }

}

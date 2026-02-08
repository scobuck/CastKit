import Foundation
// SwiftyJSON is vendored in the same module

public class AppAvailability: NSObject, @unchecked Sendable {
  public var availability = [String: Bool]()
}

extension AppAvailability {
  convenience init(json: JSON) {
    self.init()

    if let availability = json[CastJSONPayloadKeys.availability].dictionaryObject as? [String: String] {
      self.availability = availability.mapValues { $0 == "APP_AVAILABLE" }
    }
  }
}

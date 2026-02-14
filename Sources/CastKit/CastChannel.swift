import Foundation
// SwiftyJSON is vendored in the same module

open class CastChannel: NSObject {
  let namespace: String
  weak var requestDispatcher: RequestDispatchable!

  init(namespace: String) {
    self.namespace = namespace
    super.init()
  }

  open func handleResponse(_ json: JSON, sourceId: String) {
  }

  open func handleResponse(_ data: Data, sourceId: String) {
    #if DEBUG
    print("\n--Binary response--\n")
    #endif
  }

  public func send(_ request: CastRequest, response: CastResponseHandler? = nil) {
    requestDispatcher.send(request, response: response)
  }
}

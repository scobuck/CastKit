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

  /// Sends through the client this channel is attached to. A channel that
  /// has been detached — the client disconnected while a timer or a late
  /// caller still held it — answers "not connected" instead of trapping.
  public func send(_ request: CastRequest, response: CastResponseHandler? = nil) {
    guard let dispatcher = requestDispatcher else {
      response?(.failure(.notConnected))
      return
    }
    dispatcher.send(request, response: response)
  }
}

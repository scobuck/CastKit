import Foundation
// SwiftyJSON is vendored in the same module

/// An app's own namespace ("urn:x-cast:com.example.app"): messages to the receiver app it
/// launched, and what that app sends back. A reply that carries the request's `requestId`
/// completes the request; anything else is handed to `onMessage`.
final class CustomChannel: CastChannel, @unchecked Sendable {
  /// The receiver app's message, as JSON text, with the id of whoever sent it.
  var onMessage: (@Sendable (_ text: String, _ sourceId: String) -> Void)?

  override func handleResponse(_ json: JSON, sourceId: String) {
    // Replies to a request reach their caller through the client's response table.
    if let requestId = json[CastJSONPayloadKeys.requestId].int, requestId != 0 { return }
    guard let text = json.rawString(options: []) else { return }
    onMessage?(text, sourceId)
  }

  func send(_ payload: [String: Any], to app: CastApp, completion: (@Sendable (Result<String, CastError>) -> Void)?) {
    guard let dispatcher = requestDispatcher else {
      completion?(.failure(.notConnected))
      return
    }
    let request = dispatcher.request(withNamespace: namespace, destinationId: app.transportId, payload: payload)
    if let completion {
      send(request) { result in
        switch result {
        case .success(let json): completion(.success(json.rawString(options: []) ?? "{}"))
        case .failure(let error): completion(.failure(error))
        }
      }
    } else {
      send(request)
    }
  }
}

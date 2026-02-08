import Foundation

protocol RequestDispatchable: AnyObject {
  func nextRequestId() -> Int

  func request(withNamespace namespace: String, destinationId: String, payload: [String: Any]) -> CastRequest
  func request(withNamespace namespace: String, destinationId: String, payload: Data) -> CastRequest

  func send(_ request: CastRequest, response: CastResponseHandler?)
}

extension RequestDispatchable {
  func request(withNamespace namespace: String, destinationId: String, payload: [String: Any]) -> CastRequest {
    var payload = payload
    let requestId = nextRequestId()
    payload[CastJSONPayloadKeys.requestId] = requestId

    return CastRequest(id: requestId,
                       namespace: namespace,
                       destinationId: destinationId,
                       payload: payload)
  }

  func request(withNamespace namespace: String, destinationId: String, payload: Data) -> CastRequest {
    return CastRequest(id: nextRequestId(),
                       namespace: namespace,
                       destinationId: destinationId,
                       payload: payload)
  }
}

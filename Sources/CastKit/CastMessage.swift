import Foundation

typealias CastMessage = Extensions_Api_CastChannel_CastMessage

extension CastMessage {
  static func encodedMessage(payload: CastPayload, namespace: String, sourceId: String, destinationId: String) throws -> Data {
    var message = CastMessage()
    message.protocolVersion = .castv210
    message.sourceID = sourceId
    message.destinationID = destinationId
    message.namespace = namespace

    switch payload {
    case .json(let payload):
      let json = try JSONSerialization.data(withJSONObject: payload, options: [])

      guard let jsonString = String(data: json, encoding: .utf8) else {
        throw CastError.request("Failed to form JSON string from payload")
      }

      message.payloadType = .string
      message.payloadUtf8 = jsonString
    case .data(let payload):
      message.payloadType = .binary
      message.payloadBinary = payload
    }

    return try message.serializedData()
  }
}

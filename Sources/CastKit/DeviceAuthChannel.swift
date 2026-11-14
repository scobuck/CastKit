import Foundation

/// The device-auth namespace's two messages: the challenge CastClient sends
/// first on every TLS connection, before anything else, and the receiver's
/// reply. Platform to platform ("sender-0" to "receiver-0"), binary, as
/// Chromium's CreateAuthChallengeMessage sends it.
enum DeviceAuthChannel {
  /// A framed-ready CastMessage carrying `CastDeviceAuthenticator.challenge(nonce:)`.
  static func challengeMessage(nonce: Data) throws -> Data {
    try CastMessage.encodedMessage(payload: .data(CastDeviceAuthenticator.challenge(nonce: nonce)),
                                   namespace: CastNamespace.auth,
                                   sourceId: CastConstants.sender,
                                   destinationId: CastConstants.receiver)
  }

  /// The DeviceAuthMessage in the receiver's first message. Anything else
  /// first is a failure, as in Chromium's AuthTransportDelegate.
  static func replyPayload(_ message: CastMessage) throws -> Data {
    guard message.namespace == CastNamespace.auth else {
      throw CastDeviceAuthFailure.unexpectedMessage(namespace: message.namespace)
    }
    guard message.payloadType == .binary else {
      throw CastDeviceAuthFailure.malformedReply("wrong payload type")
    }
    guard message.hasPayloadBinary else {
      throw CastDeviceAuthFailure.malformedReply("no payload")
    }
    return message.payloadBinary
  }
}

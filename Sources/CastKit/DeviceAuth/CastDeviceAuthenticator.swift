import CryptoKit
import Foundation
import Security
import SwiftProtobuf

/// Why a receiver failed Cast device authentication.
enum CastDeviceAuthFailure: Error, Equatable, CustomStringConvertible {
  /// The TLS layer gave no peer certificate to bind the signature to.
  case noPeerCertificate
  /// The receiver sent something other than its auth reply first.
  case unexpectedMessage(namespace: String)
  /// The reply couldn't be read as a DeviceAuthMessage with a response.
  case malformedReply(String)
  /// The receiver answered the challenge with an AuthError.
  case deviceError(String)
  /// The TLS certificate's validity: not yet valid, expired, or longer than
  /// Cast devices make them.
  case tlsCertificate(String)
  /// The reply's sender_nonce isn't the challenge's.
  case nonceMismatch
  /// No certificates in the reply, or one that can't be parsed.
  case certificates(String)
  /// A certificate in the chain is outside its validity period.
  case certificateDate(String)
  /// The chain doesn't lead to a trusted Cast root, or fails Chromium's rules for it.
  case untrustedChain(String)
  /// The device certificate lacks what Chromium requires of it.
  case certificateRestrictions(String)
  /// A certificate in the chain is revoked.
  case revoked(String)
  /// No valid CRL (the device's nor the fallback) to check revocation against.
  case noValidCRL
  /// The reply carries no signature.
  case emptySignature
  /// The signature doesn't verify with the device certificate's key.
  case badSignature(String)
  /// An audio-only device certificate on a device that advertises video out.
  case audioOnlyPolicy

  var description: String {
    switch self {
    case .noPeerCertificate: return "the receiver presented no TLS certificate"
    case .unexpectedMessage(let namespace): return "the receiver sent \(namespace) before answering the auth challenge"
    case .malformedReply(let detail): return "unreadable auth reply (\(detail))"
    case .deviceError(let type): return "the receiver refused the auth challenge (\(type))"
    case .tlsCertificate(let detail): return "TLS certificate \(detail)"
    case .nonceMismatch: return "the reply's nonce isn't the challenge's"
    case .certificates(let detail): return detail
    case .certificateDate(let detail): return "certificate outside its validity period (\(detail))"
    case .untrustedChain(let detail): return "the device certificate doesn't chain to a Cast root (\(detail))"
    case .certificateRestrictions(let detail): return "device certificate \(detail)"
    case .revoked(let detail): return "revoked certificate (\(detail))"
    case .noValidCRL: return "no valid CRL to check revocation against"
    case .emptySignature: return "the reply has no signature"
    case .badSignature(let detail): return "the signature doesn't verify (\(detail))"
    case .audioOnlyPolicy: return "an audio-only device certificate on a device that advertises video"
    }
  }
}

/// What a successful authentication established.
struct CastDeviceAuthResult: Sendable, Equatable {
  /// Common names from the device certificate up to the trust anchor.
  let chain: [String]
  /// The trust anchor the chain reached.
  var rootName: String { chain.last ?? "" }
  /// The algorithm the signature was verified with (always RSASSA-PKCS1-v1_5, as in Chromium).
  let signatureAlgorithm: String
  /// The digest the device signed with: "SHA-256", or "SHA-1" from older devices.
  let hashAlgorithm: String
  /// The algorithm the device's reply named, for the record.
  let declaredSignatureAlgorithm: String
  /// The chain carries Cast's audio-only policy.
  let isAudioOnly: Bool
  /// The chain had expired and passed under Chromium's long-term grace.
  let usedLongTermExpiryGrace: Bool
  /// Which CRLs the chain was checked against.
  let revocation: Revocation

  enum Revocation: String, Sendable {
    /// The device's own CRL (and the fallback CRL).
    case deviceCRL = "device CRL"
    /// The device sent no CRL; the fallback CRL only.
    case fallbackCRL = "fallback CRL (device sent none)"
    /// The device's CRL didn't verify; the fallback CRL only.
    case fallbackCRLDeviceCRLInvalid = "fallback CRL (device CRL invalid)"
    /// No CRL configured (tests).
    case none = "none"
  }
}

/// Cast device authentication, verified the way Chromium does it
/// (components/media_router/common/providers/cast/channel/cast_auth_util.cc
/// and .../certificate/cast_cert_validator.cc, cast_crl.cc).
///
/// The receiver answers the challenge with its device certificate, the
/// intermediates up to a Google Cast root, and a signature over
/// `sender_nonce || DER of its TLS certificate` made with the device key.
/// The signature binds the TLS session to a Google-issued device key, which
/// nothing else on the network has.
///
/// Where CastKit differs from Chromium:
/// - The nonce must come back unchanged. Chromium (and Open Screen) only
///   record a missing or different nonce and go on.
/// - The fallback CRL's revocations always apply. Chromium gives it 20 weeks
///   from the browser's build, then refuses devices that send no CRL of their
///   own; a library has no build date its users update with, so CastKit keeps
///   the revocations and drops the deadline.
/// - Apple's evaluator doesn't verify RSASSA-PSS certificate signatures, which
///   Chromium's path builder accepts, so a PSS-signed chain is refused. Cast's
///   PKI signs with RSASSA-PKCS1-v1_5.
struct CastDeviceAuthenticator: Sendable {
  /// DER certificates the device chain must reach.
  var trustAnchors: [Data]
  /// DER certificates CRL signers must chain to.
  var crlTrustAnchors: [Data]
  /// A CRL bundle applied whether or not the device sends one; nil for none.
  var fallbackCRL: Data?
  /// When the fallback CRL's signer chain is checked.
  var fallbackCRLSignerCheckTime: Date

  /// Google's Cast roots and Chromium's fallback CRL.
  static let google = CastDeviceAuthenticator(
    trustAnchors: [CastTrustRoots.castRootCA, CastTrustRoots.eurekaRootCA],
    crlTrustAnchors: [CastTrustRoots.castCRLRootCA],
    fallbackCRL: CastTrustRoots.fallbackCRL,
    fallbackCRLSignerCheckTime: CastTrustRoots.fallbackCRLSignerCheckTime)

  typealias AuthMessage = Extensions_Api_CastChannel_DeviceAuthMessage
  typealias AuthResponse = Extensions_Api_CastChannel_AuthResponse

  /// Chromium: kMaxSelfSignedCertLifetimeInDays.
  static let maxTLSCertificateLifetime: TimeInterval = 4 * 24 * 3600
  /// Chromium: kNonceSizeInBytes.
  static let nonceSize = 16
  /// Cast's audio-only device policy, 1.3.6.1.4.1.11129.2.5.2.
  static let audioOnlyPolicyOID = "1.3.6.1.4.1.11129.2.5.2"

  /// The certificate signature algorithms Chromium's CastPathBuilderDelegate
  /// accepts (SimplePathBuilderDelegate with kWeakAllowSha1).
  static let acceptedCertificateSignatures: Set<String> = [
    "1.2.840.113549.1.1.5",   // sha1WithRSAEncryption
    "1.2.840.113549.1.1.11",  // sha256WithRSAEncryption
    "1.2.840.113549.1.1.12",  // sha384WithRSAEncryption
    "1.2.840.113549.1.1.13",  // sha512WithRSAEncryption
    "1.2.840.113549.1.1.10",  // RSASSA-PSS (which Apple's evaluator refuses)
    "1.2.840.10045.4.1",      // ecdsa-with-SHA1
    "1.2.840.10045.4.3.2",    // ecdsa-with-SHA256
    "1.2.840.10045.4.3.3",    // ecdsa-with-SHA384
    "1.2.840.10045.4.3.4",    // ecdsa-with-SHA512
  ]

  /// A fresh 16-byte nonce from the system's secure generator. Chromium keeps
  /// one for a day; CastKit makes one per connection.
  static func makeNonce() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: nonceSize)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CastDeviceAuthFailure.malformedReply("no random bytes for the nonce")
    }
    return Data(bytes)
  }

  /// The challenge, as Chromium's CreateAuthChallengeMessage makes it: the
  /// nonce and SHA-256, the signature algorithm left at its default.
  static func challenge(nonce: Data) throws -> Data {
    var message = AuthMessage()
    message.challenge.senderNonce = nonce
    message.challenge.hashAlgorithm = .sha256
    return try message.serializedBytes()
  }

  // MARK: - AuthenticateChallengeReply

  /// Checks a reply to `challenge(nonce:)`. `peerCertificate` is the DER of
  /// the certificate the receiver presented in the TLS handshake.
  func authenticate(reply payload: Data, nonce: Data, peerCertificate: Data,
                    deviceCapabilities: DeviceCapabilities = [], at time: Date = Date()) throws -> CastDeviceAuthResult {
    // ParseAuthMessage
    let message: AuthMessage
    do {
      message = try AuthMessage(serializedBytes: payload)
    } catch {
      throw CastDeviceAuthFailure.malformedReply("not a DeviceAuthMessage")
    }
    if message.hasError {
      throw CastDeviceAuthFailure.deviceError(Self.name(of: message.error.errorType))
    }
    guard message.hasResponse else {
      throw CastDeviceAuthFailure.malformedReply("no response")
    }
    let response = message.response

    // VerifyTLSCertificate
    try Self.checkTLSCertificate(peerCertificate, at: time)

    // VerifySenderNonce, strict.
    guard response.senderNonce == nonce else {
      throw CastDeviceAuthFailure.nonceMismatch
    }

    let result = try verifyCredentials(response, signatureInput: response.senderNonce + peerCertificate, at: time)

    // CastSocketImpl::VerifyChannelPolicy
    if result.isAudioOnly, deviceCapabilities.contains(.videoOut) {
      throw CastDeviceAuthFailure.audioOnlyPolicy
    }
    return result
  }

  /// The TLS certificate isn't verified as X.509; its validity window is the
  /// signature's expiry, and Cast devices make them for two days.
  static func checkTLSCertificate(_ der: Data, at time: Date) throws {
    let certificate: X509Certificate
    do {
      certificate = try X509Certificate(der: der)
    } catch {
      throw CastDeviceAuthFailure.tlsCertificate("can't be read")
    }
    if certificate.notBefore > time {
      throw CastDeviceAuthFailure.tlsCertificate("isn't valid yet")
    }
    if certificate.notAfter < time {
      throw CastDeviceAuthFailure.tlsCertificate("has expired")
    }
    if certificate.notAfter > time.addingTimeInterval(maxTLSCertificateLifetime) {
      throw CastDeviceAuthFailure.tlsCertificate("lifetime is too long")
    }
  }

  // MARK: - VerifyCredentials

  /// The chain to a Cast root, revocation, then the signature over `signatureInput`.
  func verifyCredentials(_ response: AuthResponse, signatureInput: Data, at time: Date) throws -> CastDeviceAuthResult {
    let chainDER = [response.clientAuthCertificate] + response.intermediateCertificate

    // Parse the CRLs. A device CRL that doesn't verify is set aside, as in Chromium.
    var deviceCRL: VerifiedCRL?
    var deviceCRLInvalid = false
    if !response.crl.isEmpty {
      deviceCRL = verifiedCRL(response.crl, at: time, isFallback: false)
      deviceCRLInvalid = deviceCRL == nil
    }
    let fallback = fallbackCRL.flatMap { verifiedCRL($0, at: time, isFallback: true) }

    let device = try verifyDeviceCertificate(chainDER, at: time)

    // Revocation, CRL_REQUIRED_WITH_FALLBACK as Chromium's VerifyCredentials uses it.
    let revocation: CastDeviceAuthResult.Revocation
    if fallbackCRL != nil {
      if let fallback {
        if !fallback.allows(device.path, at: time) {
          throw CastDeviceAuthFailure.revoked("by the fallback CRL")
        }
      } else if deviceCRL == nil {
        throw CastDeviceAuthFailure.noValidCRL
      }
    }
    if let deviceCRL {
      if !deviceCRL.allows(device.path, at: time) {
        throw CastDeviceAuthFailure.revoked("by the device's CRL")
      }
      revocation = .deviceCRL
    } else if fallbackCRL != nil {
      revocation = deviceCRLInvalid ? .fallbackCRLDeviceCRLInvalid : .fallbackCRL
    } else {
      revocation = .none
    }

    // The signature.
    if response.signature.isEmpty, !signatureInput.isEmpty {
      throw CastDeviceAuthFailure.emptySignature
    }
    let algorithm: SecKeyAlgorithm
    let hashName: String
    switch response.hashAlgorithm {
    case .sha1:
      algorithm = .rsaSignatureMessagePKCS1v15SHA1
      hashName = "SHA-1"
    case .sha256:
      algorithm = .rsaSignatureMessagePKCS1v15SHA256
      hashName = "SHA-256"
    }
    let declared = Self.name(of: response.signatureAlgorithm)
    // Chromium verifies RSASSA-PKCS1-v1_5 whatever the reply names, and only with an RSA key.
    var error: Unmanaged<CFError>?
    guard Self.keyType(device.publicKey) == kSecAttrKeyTypeRSA as String,
          SecKeyVerifySignature(device.publicKey, algorithm, signatureInput as CFData,
                                response.signature as CFData, &error) else {
      error?.release()
      throw CastDeviceAuthFailure.badSignature("RSASSA-PKCS1-v1_5 with \(hashName); the reply named \(declared)")
    }

    return CastDeviceAuthResult(chain: device.names, signatureAlgorithm: "RSASSA-PKCS1-v1_5", hashAlgorithm: hashName,
                                declaredSignatureAlgorithm: declared, isAudioOnly: device.isAudioOnly,
                                usedLongTermExpiryGrace: device.usedGrace, revocation: revocation)
  }

  // MARK: - VerifyDeviceCert

  struct VerifiedDevice {
    /// The path from the device certificate to the trust anchor, inclusive.
    let path: [X509Certificate]
    let names: [String]
    let publicKey: SecKey
    let isAudioOnly: Bool
    let usedGrace: Bool
  }

  func verifyDeviceCertificate(_ chainDER: [Data], at time: Date) throws -> VerifiedDevice {
    guard let first = chainDER.first, !first.isEmpty else {
      throw CastDeviceAuthFailure.certificates("no device certificate")
    }
    var certificates: [SecCertificate] = []
    var parsed: [X509Certificate] = []
    for der in chainDER {
      guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
            let info = try? X509Certificate(der: der) else {
        throw CastDeviceAuthFailure.certificates("a certificate in the reply can't be parsed")
      }
      certificates.append(certificate)
      parsed.append(info)
    }

    let (validationDate, usedGrace) = Self.validationDate(target: parsed[0], certificates: parsed, at: time)

    // Path building and RFC 5280 verification to the trust anchors.
    let path = try Self.evaluate(certificates, anchors: trustAnchors, at: validationDate)

    // CastPathBuilderDelegate and KeyPurpose::CLIENT_AUTH, for what the
    // Security framework doesn't check.
    let pathInfo = try path.map { try X509Certificate(der: SecCertificateCopyData($0) as Data) }
    for (index, certificate) in path.enumerated() {
      try Self.checkPublicKey(of: certificate)
      let info = pathInfo[index]
      if index < path.count - 1, !Self.acceptedCertificateSignatures.contains(info.signatureAlgorithm) {
        throw CastDeviceAuthFailure.untrustedChain("signature algorithm \(info.signatureAlgorithm) isn't accepted")
      }
      if let eku = info.extendedKeyUsage,
         !eku.contains(X509Certificate.clientAuthOID), !eku.contains(X509Certificate.anyExtendedKeyUsageOID) {
        throw CastDeviceAuthFailure.untrustedChain("extended key usage without TLS client authentication")
      }
    }

    // DetermineDeviceCertificatePolicy: any certificate on the path, root included.
    let isAudioOnly = pathInfo.contains { $0.policies.contains(Self.audioOnlyPolicyOID) }

    // CheckTargetCertificate.
    let target = path[0]
    guard pathInfo[0].assertsDigitalSignature else {
      throw CastDeviceAuthFailure.certificateRestrictions("key usage lacks digitalSignature")
    }
    var commonName: CFString?
    guard SecCertificateCopyCommonName(target, &commonName) == errSecSuccess,
          let name = commonName as String?, !name.isEmpty else {
      throw CastDeviceAuthFailure.certificateRestrictions("has no common name")
    }
    guard let key = SecCertificateCopyKey(target) else {
      throw CastDeviceAuthFailure.certificateRestrictions("public key can't be read")
    }

    let names = path.map { certificate -> String in
      var cn: CFString?
      SecCertificateCopyCommonName(certificate, &cn)
      return (cn as String?) ?? "?"
    }
    return VerifiedDevice(path: pathInfo, names: names, publicKey: key, isAudioOnly: isAudioOnly, usedGrace: usedGrace)
  }

  /// Chromium's GetValidationDate (b/416790717): a chain of long-term
  /// certificates (every one valid for over five years) that has expired is
  /// checked a week before the first expiry instead, for fifteen years after
  /// the device certificate's own expiry. Cast devices whose intermediates
  /// expired in 2025 keep working this way.
  static func validationDate(target: X509Certificate, certificates: [X509Certificate], at time: Date) -> (Date, Bool) {
    let day: TimeInterval = 24 * 3600
    let minNotAfter = certificates.map(\.notAfter).min() ?? time
    let minValidity = certificates.map { $0.notAfter.timeIntervalSince($0.notBefore) }.min() ?? 0
    let maxValidityDate = target.notAfter.addingTimeInterval(15 * 365 * day)
    if minNotAfter <= time, time <= maxValidityDate, minValidity > 5 * 365 * day {
      return (minNotAfter.addingTimeInterval(-7 * day), true)
    }
    return (time, false)
  }

  /// Evaluates `certificates` (target first) against `anchors` alone, at
  /// `date`, without fetching anything. Returns the path, anchor included.
  static func evaluate(_ certificates: [SecCertificate], anchors: [Data], at date: Date) throws -> [SecCertificate] {
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
          let trust else {
      throw CastDeviceAuthFailure.untrustedChain("no trust object")
    }
    let anchorCertificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    SecTrustSetNetworkFetchAllowed(trust, false)
    SecTrustSetVerifyDate(trust, date as CFDate)
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
      let code = error.map { CFErrorGetCode($0) } ?? 0
      let text = error.map { CFErrorCopyDescription($0) as String } ?? "not trusted"
      if code == Int(errSecCertificateExpired) || code == Int(errSecCertificateNotValidYet) {
        throw CastDeviceAuthFailure.certificateDate(text)
      }
      throw CastDeviceAuthFailure.untrustedChain(text)
    }
    guard let path = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !path.isEmpty else {
      throw CastDeviceAuthFailure.untrustedChain("no path to an anchor")
    }
    return path
  }

  /// SimplePathBuilderDelegate::IsPublicKeyAcceptable: RSA keys of 2048 bits
  /// or more, or ECDSA on P-256, P-384 or P-521.
  static func checkPublicKey(of certificate: SecCertificate) throws {
    guard let key = SecCertificateCopyKey(certificate),
          let attributes = SecKeyCopyAttributes(key) as? [String: Any] else {
      throw CastDeviceAuthFailure.untrustedChain("a public key can't be read")
    }
    let bits = (attributes[kSecAttrKeySizeInBits as String] as? Int) ?? 0
    let type = keyType(key)
    if type == kSecAttrKeyTypeRSA as String, bits >= 2048 { return }
    if type == kSecAttrKeyTypeECSECPrimeRandom as String, [256, 384, 521].contains(bits) { return }
    throw CastDeviceAuthFailure.untrustedChain("unacceptable public key (\(bits) bits)")
  }

  static func keyType(_ key: SecKey) -> String? {
    (SecKeyCopyAttributes(key) as? [String: Any])?[kSecAttrKeyType as String] as? String
  }

  static func name(of error: Extensions_Api_CastChannel_AuthError.ErrorType) -> String {
    switch error {
    case .internalError: return "INTERNAL_ERROR"
    case .noTls: return "NO_TLS"
    case .signatureAlgorithmUnavailable: return "SIGNATURE_ALGORITHM_UNAVAILABLE"
    }
  }

  static func name(of algorithm: Extensions_Api_CastChannel_SignatureAlgorithm) -> String {
    switch algorithm {
    case .unspecified: return "UNSPECIFIED"
    case .rsassaPkcs1V15: return "RSASSA_PKCS1v15"
    case .rsassaPss: return "RSASSA_PSS"
    }
  }

  // MARK: - CRL

  /// A CRL that verified: its window and what it revokes.
  struct VerifiedCRL {
    let notBefore: Date
    let notAfter: Date
    /// The fallback CRL's window isn't checked (see the type's notes).
    let checksTime: Bool
    let revokedKeyHashes: Set<Data>
    let revokedSerials: [Data: [ClosedRange<UInt64>]]

    /// CastCRLImpl::CheckRevocation over a verified path (anchor included):
    /// false when the CRL isn't current or revokes a key or serial on it.
    func allows(_ path: [X509Certificate], at time: Date) -> Bool {
      guard !path.isEmpty else { return false }
      if checksTime, time < notBefore || time > notAfter { return false }
      for (index, certificate) in path.enumerated() {
        let keyHash = Data(SHA256.hash(data: certificate.subjectPublicKeyInfo))
        if revokedKeyHashes.contains(keyHash) { return false }
        if index > 0, let ranges = revokedSerials[keyHash],
           let serial = path[index - 1].serialNumberUInt64,
           ranges.contains(where: { $0.contains(serial) }) {
          return false
        }
      }
      return true
    }
  }

  typealias CrlBundle = CastCertificate_CrlBundle
  typealias TbsCrl = CastCertificate_TbsCrl

  /// ParseAndVerifyCRLUsingCustomTrustStore and VerifyCRL: the first
  /// version-0 CRL in the bundle decides.
  func verifiedCRL(_ data: Data, at time: Date, isFallback: Bool) -> VerifiedCRL? {
    guard let bundle = try? CrlBundle(serializedBytes: data) else { return nil }
    for crl in bundle.crls {
      guard let tbs = try? TbsCrl(serializedBytes: crl.tbsCrl), tbs.version == 0 else { continue }
      guard crl.hasSignature, crl.hasSignerCert,
            let signer = SecCertificateCreateWithData(nil, crl.signerCert as CFData),
            let key = SecCertificateCopyKey(signer),
            Self.keyType(key) == kSecAttrKeyTypeRSA as String,
            SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, crl.tbsCrl as CFData,
                                  crl.signature as CFData, nil) else {
        return nil
      }
      // The signer chains to a CRL root (no key usage required of it).
      let checkTime = isFallback ? fallbackCRLSignerCheckTime : time
      guard let path = try? Self.evaluate([signer], anchors: crlTrustAnchors, at: checkTime) else { return nil }
      do {
        try path.forEach(Self.checkPublicKey)
      } catch {
        return nil
      }
      let notBefore = Date(timeIntervalSince1970: TimeInterval(tbs.notBeforeSeconds))
      var notAfter = Date(timeIntervalSince1970: TimeInterval(tbs.notAfterSeconds))
      if !isFallback {
        if time < notBefore || time > notAfter { return nil }
        // The CRL lasts no longer than its signer chain (the anchor aside).
        for certificate in path.dropLast() {
          if let info = try? X509Certificate(der: SecCertificateCopyData(certificate) as Data), info.notAfter < notAfter {
            notAfter = info.notAfter
          }
        }
      }
      var serials: [Data: [ClosedRange<UInt64>]] = [:]
      for range in tbs.revokedSerialNumberRanges {
        guard range.lastSerialNumber >= range.firstSerialNumber else { return nil }
        serials[range.issuerPublicKeyHash, default: []].append(range.firstSerialNumber...range.lastSerialNumber)
      }
      return VerifiedCRL(notBefore: notBefore, notAfter: notAfter, checksTime: !isFallback,
                         revokedKeyHashes: Set(tbs.revokedPublicKeyHashes), revokedSerials: serials)
    }
    return nil
  }
}

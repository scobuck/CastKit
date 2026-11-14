import CryptoKit
import Security
import SwiftProtobuf
import XCTest
@testable import CastKit

/// A fake Cast PKI (Fixtures/DeviceAuth, made by make-fixtures.sh) standing in
/// for Google's: the verifier takes its trust anchors as a parameter.
enum AuthFixtures {
  static func data(_ name: String) -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("DeviceAuth/\(name).der")
    return try! Data(contentsOf: url)
  }

  /// The tests' clock: inside the TLS certificates' two days.
  static let now: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!
  }()

  static func privateKey(_ name: String) -> SecKey {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                     kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
    return SecKeyCreateWithData(data(name) as CFData, attributes as CFDictionary, nil)!
  }

  nonisolated(unsafe) static let deviceKey = privateKey("device.key")
  nonisolated(unsafe) static let crlSignerKey = privateKey("crl-signer.key")

  static func sign(_ data: Data, with key: SecKey = deviceKey,
                   _ algorithm: SecKeyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256) -> Data {
    SecKeyCreateSignature(key, algorithm, data as CFData, nil)! as Data
  }

  static func keyHash(_ certificate: String) -> Data {
    let info = try! X509Certificate(der: data(certificate))
    return Data(SHA256.hash(data: info.subjectPublicKeyInfo))
  }

  /// A DeviceAuthMessage reply. By default: the good chain, the nonce echoed,
  /// signed with SHA-256 RSASSA-PKCS1-v1_5 over nonce || tls.der.
  static func reply(nonce: Data, chain: [String] = ["device", "ica"], tls: String = "tls",
                    signedNonce: Data? = nil, signedTLS: String? = nil,
                    key: SecKey = deviceKey,
                    algorithm: SecKeyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256,
                    hash: Extensions_Api_CastChannel_HashAlgorithm = .sha256,
                    declared: Extensions_Api_CastChannel_SignatureAlgorithm? = nil,
                    echoedNonce: Data? = nil, crl: Data? = nil, signature: Data? = nil) -> Data {
    var message = Extensions_Api_CastChannel_DeviceAuthMessage()
    message.response.clientAuthCertificate = data(chain[0])
    message.response.intermediateCertificate = chain.dropFirst().map(data)
    message.response.senderNonce = echoedNonce ?? nonce
    message.response.hashAlgorithm = hash
    if let declared { message.response.signatureAlgorithm = declared }
    if let crl { message.response.crl = crl }
    message.response.signature = signature
      ?? sign((signedNonce ?? echoedNonce ?? nonce) + data(signedTLS ?? tls), with: key, algorithm)
    return try! message.serializedBytes()
  }

  /// A CRL bundle signed by the test CRL signer.
  static func crl(revokingKeys keys: [Data] = [], serials: [(issuer: Data, range: ClosedRange<UInt64>)] = [],
                  from: Date = now.addingTimeInterval(-86_400), to: Date = now.addingTimeInterval(86_400),
                  signer: String = "crl-signer", signerKey: SecKey = crlSignerKey,
                  corruptSignature: Bool = false) -> Data {
    var tbs = CastCertificate_TbsCrl()
    tbs.version = 0
    tbs.notBeforeSeconds = UInt64(from.timeIntervalSince1970)
    tbs.notAfterSeconds = UInt64(to.timeIntervalSince1970)
    tbs.revokedPublicKeyHashes = keys
    tbs.revokedSerialNumberRanges = serials.map { entry in
      var range = CastCertificate_SerialNumberRange()
      range.issuerPublicKeyHash = entry.issuer
      range.firstSerialNumber = entry.range.lowerBound
      range.lastSerialNumber = entry.range.upperBound
      return range
    }
    let tbsBytes: Data = try! tbs.serializedBytes()
    var signature = sign(tbsBytes, with: signerKey)
    if corruptSignature { signature[signature.startIndex] ^= 0xFF }
    var crl = CastCertificate_Crl()
    crl.tbsCrl = tbsBytes
    crl.signerCert = data(signer)
    crl.signature = signature
    var bundle = CastCertificate_CrlBundle()
    bundle.crls = [crl]
    return try! bundle.serializedBytes()
  }

  static func authenticator(fallbackCRL: Data? = nil) -> CastDeviceAuthenticator {
    CastDeviceAuthenticator(trustAnchors: [data("root")], crlTrustAnchors: [data("crl-root")],
                            fallbackCRL: fallbackCRL, fallbackCRLSignerCheckTime: now)
  }
}

final class CastDeviceAuthTests: XCTestCase {
  private let nonce = Data((0..<16).map { UInt8($0 * 7 + 3) })
  private var tls: Data { AuthFixtures.data("tls") }

  private func authenticate(_ reply: Data, verifier: CastDeviceAuthenticator = AuthFixtures.authenticator(),
                            capabilities: DeviceCapabilities = [], at time: Date = AuthFixtures.now) throws -> CastDeviceAuthResult {
    try verifier.authenticate(reply: reply, nonce: nonce, peerCertificate: tls,
                              deviceCapabilities: capabilities, at: time)
  }

  private func assertFails(_ reply: Data, verifier: CastDeviceAuthenticator = AuthFixtures.authenticator(),
                           capabilities: DeviceCapabilities = [], at time: Date = AuthFixtures.now,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ check: (CastDeviceAuthFailure) -> Bool) {
    do {
      let result = try authenticate(reply, verifier: verifier, capabilities: capabilities, at: time)
      XCTFail("authenticated: \(result)", file: file, line: line)
    } catch let failure as CastDeviceAuthFailure {
      XCTAssertTrue(check(failure), "unexpected failure: \(failure)", file: file, line: line)
    } catch {
      XCTFail("unexpected error \(error)", file: file, line: line)
    }
  }

  // MARK: - The good case

  func testGoodChainAndSignature() throws {
    let result = try authenticate(AuthFixtures.reply(nonce: nonce))
    XCTAssertEqual(result.chain, ["CastKit Test Device", "CastKit Test ICA", "CastKit Test Root CA"])
    XCTAssertEqual(result.rootName, "CastKit Test Root CA")
    XCTAssertEqual(result.signatureAlgorithm, "RSASSA-PKCS1-v1_5")
    XCTAssertEqual(result.hashAlgorithm, "SHA-256")
    XCTAssertFalse(result.isAudioOnly)
    XCTAssertFalse(result.usedLongTermExpiryGrace)
  }

  func testTheChallengeCarriesTheNonceAndAsksForSHA256() throws {
    let nonce = try CastDeviceAuthenticator.makeNonce()
    XCTAssertEqual(nonce.count, 16)
    XCTAssertNotEqual(nonce, try CastDeviceAuthenticator.makeNonce())
    let message = try Extensions_Api_CastChannel_DeviceAuthMessage(
      serializedBytes: CastDeviceAuthenticator.challenge(nonce: nonce))
    XCTAssertEqual(message.challenge.senderNonce, nonce)
    XCTAssertEqual(message.challenge.hashAlgorithm, .sha256)
    XCTAssertFalse(message.challenge.hasSignatureAlgorithm)  // left at RSASSA-PKCS1-v1_5, as Chromium does
    XCTAssertFalse(message.hasResponse)
  }

  // MARK: - Nonce and TLS binding

  func testWrongNonceIsRefused() {
    let other = Data(repeating: 0x42, count: 16)
    assertFails(AuthFixtures.reply(nonce: nonce, echoedNonce: other)) { $0 == .nonceMismatch }
  }

  func testMissingNonceIsRefused() {
    // Chromium records this and goes on; CastKit requires the echo.
    assertFails(AuthFixtures.reply(nonce: nonce, echoedNonce: Data())) { $0 == .nonceMismatch }
  }

  func testSignatureOverAnotherNonceIsRefused() {
    assertFails(AuthFixtures.reply(nonce: nonce, signedNonce: Data(repeating: 1, count: 16))) {
      if case .badSignature = $0 { return true } else { return false }
    }
  }

  func testSignatureOverADifferentTLSCertificateIsRefused() {
    // A device's genuine signature, replayed on a connection with another TLS certificate.
    assertFails(AuthFixtures.reply(nonce: nonce, signedTLS: "tls-other")) {
      if case .badSignature = $0 { return true } else { return false }
    }
  }

  func testTLSCertificateValidityFollowsChromium() {
    let reply = AuthFixtures.reply(nonce: nonce)
    // Expired: two days later.
    assertFails(reply, at: AuthFixtures.now.addingTimeInterval(2 * 86_400)) { $0 == .tlsCertificate("has expired") }
    // Not yet valid: 36 hours earlier (its start, a day earlier, is still valid).
    assertFails(reply, at: AuthFixtures.now.addingTimeInterval(-36 * 3600)) { $0 == .tlsCertificate("isn't valid yet") }
    XCTAssertNoThrow(try authenticate(reply, at: AuthFixtures.now.addingTimeInterval(-86_400)))
    // Valid for more than four days from now.
    XCTAssertThrowsError(try CastDeviceAuthenticator.checkTLSCertificate(AuthFixtures.data("tls-long"), at: AuthFixtures.now)) {
      XCTAssertEqual($0 as? CastDeviceAuthFailure, .tlsCertificate("lifetime is too long"))
    }
  }

  // MARK: - The chain

  func testUntrustedRootIsRefused() {
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["other-device", "other-ica"])) {
      if case .untrustedChain = $0 { return true } else { return false }
    }
  }

  func testTestChainIsRefusedByGooglesRoots() {
    assertFails(AuthFixtures.reply(nonce: nonce), verifier: .google) {
      if case .untrustedChain = $0 { return true } else { return false }
    }
  }

  func testMissingIntermediateIsRefused() {
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device"])) {
      if case .untrustedChain = $0 { return true } else { return false }
    }
  }

  func testExpiredCertificateIsRefused() {
    // One year, expired five years before the test time: no grace.
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device-expired", "ica"])) {
      if case .certificateDate = $0 { return true } else { return false }
    }
  }

  func testLongTermCertificateExpiredRecentlyPassesUnderChromiumsGrace() throws {
    let result = try authenticate(AuthFixtures.reply(nonce: nonce, chain: ["device-longterm-expired", "ica"]))
    XCTAssertTrue(result.usedLongTermExpiryGrace)
    // Beyond fifteen years after its expiry, no grace.
    let later = AuthFixtures.now.addingTimeInterval(16 * 365 * 86_400)
    let date = CastDeviceAuthenticator.validationDate(
      target: try X509Certificate(der: AuthFixtures.data("device-longterm-expired")),
      certificates: [try X509Certificate(der: AuthFixtures.data("device-longterm-expired")),
                     try X509Certificate(der: AuthFixtures.data("ica"))], at: later)
    XCTAssertEqual(date.0, later)
    XCTAssertFalse(date.1)
  }

  func testDeviceCertificateNeedsDigitalSignature() {
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device-nodigsig", "ica"])) {
      $0 == .certificateRestrictions("key usage lacks digitalSignature")
    }
  }

  func testExtendedKeyUsageMustAllowClientAuth() throws {
    XCTAssertNoThrow(try authenticate(AuthFixtures.reply(nonce: nonce, chain: ["device-clientauth", "ica"])))
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device-serverauth", "ica"])) {
      $0 == .untrustedChain("extended key usage without TLS client authentication")
    }
  }

  func testRSAKeysUnder2048BitsAreRefused() {
    let key = AuthFixtures.privateKey("device-1024.key")
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device-1024", "ica"], key: key)) {
      $0 == .untrustedChain("unacceptable public key (1024 bits)")
    }
  }

  func testAudioOnlyPolicy() throws {
    let reply = AuthFixtures.reply(nonce: nonce, chain: ["device-audio", "ica-audio"])
    XCTAssertTrue(try authenticate(reply, capabilities: [.audioOut]).isAudioOnly)
    // An audio-only certificate on a device that says it shows video is refused, as in Chromium.
    assertFails(reply, capabilities: [.videoOut, .audioOut]) { $0 == .audioOnlyPolicy }
  }

  // MARK: - Algorithms

  func testSHA1SignedChainIsAccepted() throws {
    // Older Cast devices have SHA-1 chains; Chromium accepts them, and so does
    // Apple's evaluator against anchors of the caller's own.
    let result = try authenticate(AuthFixtures.reply(nonce: nonce, chain: ["device-sha1", "ica-sha1"]))
    XCTAssertEqual(result.rootName, "CastKit Test Root CA")
  }

  func testSHA1AndSHA256Signatures() throws {
    let sha1 = try authenticate(AuthFixtures.reply(nonce: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA1, hash: .sha1))
    XCTAssertEqual(sha1.hashAlgorithm, "SHA-1")
    let sha256 = try authenticate(AuthFixtures.reply(nonce: nonce))
    XCTAssertEqual(sha256.hashAlgorithm, "SHA-256")
    // The digest must be the one the reply names.
    assertFails(AuthFixtures.reply(nonce: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA1, hash: .sha256)) {
      if case .badSignature = $0 { return true } else { return false }
    }
  }

  func testPKCS1SignatureIsVerifiedWhateverTheReplyNames() throws {
    // Chromium verifies RSASSA-PKCS1-v1_5 and ignores signature_algorithm.
    let result = try authenticate(AuthFixtures.reply(nonce: nonce, declared: .rsassaPss))
    XCTAssertEqual(result.signatureAlgorithm, "RSASSA-PKCS1-v1_5")
    XCTAssertEqual(result.declaredSignatureAlgorithm, "RSASSA_PSS")
  }

  func testPSSSignatureIsRefusedAsInChromium() {
    // Neither Chromium nor Open Screen verifies an RSASSA-PSS auth signature.
    assertFails(AuthFixtures.reply(nonce: nonce, algorithm: .rsaSignatureMessagePSSSHA256, declared: .rsassaPss)) {
      if case .badSignature = $0 { return true } else { return false }
    }
  }

  func testPSSSignedChainIsRefusedByApplesEvaluator() {
    // Chromium's path builder accepts RSASSA-PSS certificate signatures; the
    // Security framework doesn't verify them, so such a chain fails closed.
    // (The fixture chain verifies with OpenSSL.)
    assertFails(AuthFixtures.reply(nonce: nonce, chain: ["device-pss", "ica-pss"])) {
      if case .untrustedChain = $0 { return true } else { return false }
    }
  }

  // MARK: - Malformed and refused replies

  func testDeviceErrorIsReported() throws {
    var message = Extensions_Api_CastChannel_DeviceAuthMessage()
    message.error.errorType = .noTls
    assertFails(try message.serializedBytes()) { $0 == .deviceError("NO_TLS") }
  }

  func testGarbageAndEmptyRepliesAreRefused() throws {
    assertFails(Data([0xFF, 0x00, 0x13])) { if case .malformedReply = $0 { return true } else { return false } }
    assertFails(try Extensions_Api_CastChannel_DeviceAuthMessage().serializedBytes()) {
      $0 == .malformedReply("no response")
    }
  }

  func testEmptySignatureIsRefused() {
    assertFails(AuthFixtures.reply(nonce: nonce, signature: Data())) { $0 == .emptySignature }
  }

  // MARK: - Revocation

  func testDeviceCRLThatRevokesNothing() throws {
    let crl = AuthFixtures.crl()
    let result = try authenticate(AuthFixtures.reply(nonce: nonce, crl: crl),
                                  verifier: AuthFixtures.authenticator(fallbackCRL: AuthFixtures.crl()))
    XCTAssertEqual(result.revocation, .deviceCRL)
  }

  func testDeviceCRLRevokingTheDeviceKey() {
    let crl = AuthFixtures.crl(revokingKeys: [AuthFixtures.keyHash("device")])
    assertFails(AuthFixtures.reply(nonce: nonce, crl: crl)) { $0 == .revoked("by the device's CRL") }
  }

  func testDeviceCRLRevokingBySerialRange() {
    // The device certificate is serial 100 under the ICA's key.
    let crl = AuthFixtures.crl(serials: [(AuthFixtures.keyHash("ica"), 90...110)])
    assertFails(AuthFixtures.reply(nonce: nonce, crl: crl)) { $0 == .revoked("by the device's CRL") }
    let elsewhere = AuthFixtures.crl(serials: [(AuthFixtures.keyHash("ica"), 200...300)])
    XCTAssertNoThrow(try authenticate(AuthFixtures.reply(nonce: nonce, crl: elsewhere)))
  }

  func testInvalidDeviceCRLFallsBackToTheFallbackCRL() throws {
    let fallback = AuthFixtures.authenticator(fallbackCRL: AuthFixtures.crl())
    // Expired, badly signed, or signed by a certificate outside the CRL PKI:
    // set aside, and the fallback CRL decides, as in Chromium.
    let expired = AuthFixtures.crl(revokingKeys: [AuthFixtures.keyHash("device")],
                                   from: AuthFixtures.now.addingTimeInterval(-10 * 86_400),
                                   to: AuthFixtures.now.addingTimeInterval(-86_400))
    let forged = AuthFixtures.crl(revokingKeys: [AuthFixtures.keyHash("device")], corruptSignature: true)
    let wrongSigner = AuthFixtures.crl(signer: "device", signerKey: AuthFixtures.deviceKey)
    for crl in [expired, forged, wrongSigner] {
      let result = try authenticate(AuthFixtures.reply(nonce: nonce, crl: crl), verifier: fallback)
      XCTAssertEqual(result.revocation, .fallbackCRLDeviceCRLInvalid)
    }
    let none = try authenticate(AuthFixtures.reply(nonce: nonce), verifier: fallback)
    XCTAssertEqual(none.revocation, .fallbackCRL)
  }

  func testFallbackCRLRevocationsApply() {
    let fallback = AuthFixtures.authenticator(fallbackCRL: AuthFixtures.crl(revokingKeys: [AuthFixtures.keyHash("ica")]))
    assertFails(AuthFixtures.reply(nonce: nonce), verifier: fallback) { $0 == .revoked("by the fallback CRL") }
    // Its window doesn't matter (CastKit keeps the revocations, drops the deadline).
    let old = AuthFixtures.authenticator(fallbackCRL: AuthFixtures.crl(
      revokingKeys: [AuthFixtures.keyHash("ica")],
      from: AuthFixtures.now.addingTimeInterval(-400 * 86_400), to: AuthFixtures.now.addingTimeInterval(-300 * 86_400)))
    assertFails(AuthFixtures.reply(nonce: nonce), verifier: old) { $0 == .revoked("by the fallback CRL") }
  }

  func testNoValidCRLAtAllIsRefused() {
    // A configured fallback CRL that doesn't verify, and no device CRL: as Chromium's ERR_FALLBACK_CRL_INVALID.
    let broken = AuthFixtures.authenticator(fallbackCRL: AuthFixtures.crl(corruptSignature: true))
    assertFails(AuthFixtures.reply(nonce: nonce), verifier: broken) { $0 == .noValidCRL }
    XCTAssertNoThrow(try authenticate(AuthFixtures.reply(nonce: nonce, crl: AuthFixtures.crl()), verifier: broken))
  }

  // MARK: - Google's anchors

  func testEmbeddedRootsArePinned() {
    func fingerprint(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
    // Checked against Chromium, Open Screen, Google's Chromecast app and Google Play Services.
    XCTAssertEqual(fingerprint(CastTrustRoots.castRootCA),
                   "809AF14700B3FE2611AD597EB1584D6354313B64CCDB3390F097FA3E5826D6CA")
    XCTAssertEqual(fingerprint(CastTrustRoots.eurekaRootCA),
                   "CAF6D1E37B532203E01A76BF07187BB731CCD38801565AB2211A2C0AB7F3BC46")
    XCTAssertEqual(fingerprint(CastTrustRoots.castCRLRootCA),
                   "8B77C60291F9D62764613083F49750B1C5CAAC2D9EFBE5A28EDF301F9D84831D")
    XCTAssertEqual(fingerprint(CastTrustRoots.fallbackCRL),
                   "2576BA74902221BD1A231A67CC4FC6862BD85D438EDEC26881FA1F5DFE5E25FC")
    for root in [CastTrustRoots.castRootCA, CastTrustRoots.eurekaRootCA, CastTrustRoots.castCRLRootCA] {
      XCTAssertNotNil(SecCertificateCreateWithData(nil, root as CFData))
    }
  }

  func testChromiumsFallbackCRLVerifies() throws {
    let crl = try XCTUnwrap(CastDeviceAuthenticator.google.verifiedCRL(CastTrustRoots.fallbackCRL, at: Date(), isFallback: true))
    XCTAssertEqual(crl.revokedKeyHashes.count, 13)
    XCTAssertEqual(crl.revokedSerials.values.map(\.count).reduce(0, +), 2)
    XCTAssertFalse(crl.checksTime)
  }
}

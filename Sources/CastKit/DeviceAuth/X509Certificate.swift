import Foundation

/// The parts of an X.509 certificate that device authentication checks and
/// the Security framework doesn't expose on every supported OS: the validity
/// window, key usage, extended key usage, policies, the SubjectPublicKeyInfo
/// (whose SHA-256 the Cast CRL names) and the serial number. Signatures and
/// chain building stay with the Security framework.
struct X509Certificate {
  let der: Data
  let serialNumber: Data
  let notBefore: Date
  let notAfter: Date
  /// The whole SubjectPublicKeyInfo, tag and length included.
  let subjectPublicKeyInfo: Data
  /// The key usage bits as encoded (bit 0, digitalSignature, is the high bit
  /// of the first byte), or nil when the extension is absent.
  let keyUsage: Data?
  /// Extended key usage OIDs (dotted), or nil when the extension is absent.
  let extendedKeyUsage: [String]?
  /// Certificate policy OIDs (dotted), empty when there are none.
  let policies: [String]
  /// The algorithm the issuer signed this certificate with (dotted OID).
  let signatureAlgorithm: String

  static let keyUsageOID = "2.5.29.15"
  static let extendedKeyUsageOID = "2.5.29.37"
  static let certificatePoliciesOID = "2.5.29.32"
  static let clientAuthOID = "1.3.6.1.5.5.7.3.2"
  static let anyExtendedKeyUsageOID = "2.5.29.37.0"

  var assertsDigitalSignature: Bool {
    guard let keyUsage, let first = keyUsage.first else { return false }
    return first & 0x80 != 0
  }

  /// RFC 5280's Certificate, read far enough for the fields above.
  init(der: Data) throws {
    self.der = der
    var top = DERReader(der)
    var certificate = try top.read(.sequence).contents
    var tbs = try certificate.read(.sequence).contents
    var algorithm = try certificate.read(.sequence).contents
    signatureAlgorithm = try algorithm.read(.objectIdentifier).objectIdentifier

    if tbs.peekTag == DERReader.Tag.explicit(0) {  // version
      _ = try tbs.read(.explicit(0))
    }
    serialNumber = try tbs.read(.integer).bytes
    _ = try tbs.read(.sequence)  // signature algorithm
    _ = try tbs.read(.sequence)  // issuer
    var validity = try tbs.read(.sequence).contents
    notBefore = try validity.readTime()
    notAfter = try validity.readTime()
    _ = try tbs.read(.sequence)  // subject
    subjectPublicKeyInfo = try tbs.read(.sequence).encoded

    var keyUsage: Data?
    var extendedKeyUsage: [String]?
    var policies: [String] = []
    while !tbs.isAtEnd {
      let element = try tbs.readAny()
      guard element.tag == DERReader.Tag.explicit(3) else { continue }  // issuer/subject unique ids
      var wrapper = element.contents
      var extensions = try wrapper.read(.sequence).contents
      while !extensions.isAtEnd {
        var ext = try extensions.read(.sequence).contents
        let oid = try ext.read(.objectIdentifier).objectIdentifier
        if ext.peekTag == DERReader.Tag.boolean { _ = try ext.read(.boolean) }  // critical
        var value = try ext.read(.octetString).contents
        switch oid {
        case Self.keyUsageOID:
          let bits = try value.read(.bitString).bytes
          keyUsage = bits.count > 1 ? bits.dropFirst() : Data()
        case Self.extendedKeyUsageOID:
          var list = try value.read(.sequence).contents
          var oids: [String] = []
          while !list.isAtEnd { oids.append(try list.read(.objectIdentifier).objectIdentifier) }
          extendedKeyUsage = oids
        case Self.certificatePoliciesOID:
          var list = try value.read(.sequence).contents
          while !list.isAtEnd {
            var info = try list.read(.sequence).contents
            policies.append(try info.read(.objectIdentifier).objectIdentifier)
          }
        default:
          break
        }
      }
    }
    self.keyUsage = keyUsage
    self.extendedKeyUsage = extendedKeyUsage
    self.policies = policies
  }

  /// The serial number as an unsigned 64-bit integer, the way BoringSSL's
  /// der::ParseUint64 reads it for the CRL's serial ranges: nil when it is
  /// negative or doesn't fit.
  var serialNumberUInt64: UInt64? {
    var bytes = serialNumber[...]
    guard let first = bytes.first else { return nil }
    if first & 0x80 != 0 { return nil }  // negative
    if first == 0, bytes.count > 1 { bytes = bytes.dropFirst() }
    guard bytes.count <= 8 else { return nil }
    return bytes.reduce(0) { $0 << 8 | UInt64($1) }
  }
}

enum DERError: Error {
  case truncated
  case unexpectedTag(expected: UInt8, found: UInt8)
  case unsupportedLength
  case badTime
}

/// Reads DER, one element at a time. Only what certificates need.
struct DERReader {
  enum Tag {
    static let boolean: UInt8 = 0x01
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let utcTime: UInt8 = 0x17
    static let generalizedTime: UInt8 = 0x18
    static let sequence: UInt8 = 0x30
    static func explicit(_ n: UInt8) -> UInt8 { 0xA0 | n }
  }

  enum Expected {
    case boolean, integer, bitString, octetString, objectIdentifier, sequence
    case explicit(UInt8)

    var tag: UInt8 {
      switch self {
      case .boolean: return Tag.boolean
      case .integer: return Tag.integer
      case .bitString: return Tag.bitString
      case .octetString: return Tag.octetString
      case .objectIdentifier: return Tag.objectIdentifier
      case .sequence: return Tag.sequence
      case .explicit(let n): return Tag.explicit(n)
      }
    }
  }

  struct Element {
    let tag: UInt8
    /// The value's bytes.
    let bytes: Data
    /// The whole element: tag, length and value.
    let encoded: Data

    var contents: DERReader { DERReader(bytes) }

    var objectIdentifier: String {
      var parts: [UInt64] = []
      var value: UInt64 = 0
      for byte in bytes {
        value = value << 7 | UInt64(byte & 0x7F)
        if byte & 0x80 == 0 {
          parts.append(value)
          value = 0
        }
      }
      guard let first = parts.first else { return "" }
      let head: [UInt64] = first < 80 ? [first / 40, first % 40] : [2, first - 80]
      return (head + parts.dropFirst()).map(String.init).joined(separator: ".")
    }
  }

  private let data: Data
  private var position: Data.Index

  init(_ data: Data) {
    self.data = data
    position = data.startIndex
  }

  var isAtEnd: Bool { position >= data.endIndex }
  var peekTag: UInt8? { isAtEnd ? nil : data[position] }

  mutating func read(_ expected: Expected) throws -> Element {
    let element = try readAny()
    guard element.tag == expected.tag else {
      throw DERError.unexpectedTag(expected: expected.tag, found: element.tag)
    }
    return element
  }

  mutating func readAny() throws -> Element {
    let start = position
    guard position < data.endIndex else { throw DERError.truncated }
    let tag = data[position]
    position += 1
    guard position < data.endIndex else { throw DERError.truncated }
    var length = Int(data[position])
    position += 1
    if length & 0x80 != 0 {
      let count = length & 0x7F
      guard count > 0, count <= 4 else { throw DERError.unsupportedLength }
      guard data.endIndex - position >= count else { throw DERError.truncated }
      length = 0
      for _ in 0..<count {
        length = length << 8 | Int(data[position])
        position += 1
      }
    }
    guard data.endIndex - position >= length else { throw DERError.truncated }
    let value = data[position..<(position + length)]
    position += length
    return Element(tag: tag, bytes: Data(value), encoded: Data(data[start..<position]))
  }

  /// UTCTime (YYMMDDHHMMSSZ, years 1950–2049) or GeneralizedTime (YYYYMMDDHHMMSSZ).
  mutating func readTime() throws -> Date {
    let element = try readAny()
    guard let text = String(data: element.bytes, encoding: .ascii), text.hasSuffix("Z") else {
      throw DERError.badTime
    }
    let digits = Array(text.dropLast())
    func number(_ range: Range<Int>) throws -> Int {
      guard range.upperBound <= digits.count, let n = Int(String(digits[range])) else { throw DERError.badTime }
      return n
    }
    var components = DateComponents()
    let offset: Int
    switch element.tag {
    case Tag.utcTime:
      guard digits.count == 12 else { throw DERError.badTime }
      let year = try number(0..<2)
      components.year = year < 50 ? 2000 + year : 1900 + year
      offset = 2
    case Tag.generalizedTime:
      guard digits.count == 14 else { throw DERError.badTime }
      components.year = try number(0..<4)
      offset = 4
    default:
      throw DERError.badTime
    }
    components.month = try number(offset..<(offset + 2))
    components.day = try number((offset + 2)..<(offset + 4))
    components.hour = try number((offset + 4)..<(offset + 6))
    components.minute = try number((offset + 6)..<(offset + 8))
    components.second = try number((offset + 8)..<(offset + 10))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard let date = calendar.date(from: components) else { throw DERError.badTime }
    return date
  }
}

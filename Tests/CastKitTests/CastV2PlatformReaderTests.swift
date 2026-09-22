import XCTest
@testable import CastKit

/// The framing reader must survive frames arriving in any pieces, batches
/// that cross its compaction threshold, and payloads larger than a read.
final class CastV2PlatformReaderTests: XCTestCase {

  private func frame(_ size: Int, fill: UInt8) -> Data {
    var length = UInt32(size).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(Data(repeating: fill, count: size))
    return data
  }

  /// Feeds `bytes` through an InputStream in chunks of `chunk`, collecting messages.
  private func run(_ bytes: Data, chunk: Int) -> [Data] {
    var messages: [Data] = []
    var offset = 0
    while offset < bytes.count {
      let end = min(bytes.count, offset + chunk)
      let stream = InputStream(data: bytes.subdata(in: offset..<end))
      stream.open()
      readers[0].feed(stream)
      while let message = readers[0].reader.nextMessage() { messages.append(message) }
      stream.close()
      offset = end
    }
    return messages
  }

  /// A reader over a stand-in stream: the real one reads from the socket
  /// stream it was created with, so a small subclass swaps the source.
  private final class Feeder {
    let reader: CastV2PlatformReader
    init() { reader = CastV2PlatformReader(stream: InputStream(data: Data())) }
    func feed(_ stream: InputStream) {
      reader.readAll(from: stream)
    }
  }
  private var readers: [Feeder] = [Feeder()]

  override func setUp() { readers = [Feeder()] }

  func testFramesSplitAtEveryBoundary() {
    var bytes = Data()
    let sizes = [1, 50, 4_000, 3, 5_000, 12_000, 7, 300]
    for (i, size) in sizes.enumerated() { bytes.append(frame(size, fill: UInt8(i + 1))) }
    for chunk in [1, 3, 7, 100, 4_096, 4_097, 8_191, 8_192, 8_193, 65_536] {
      readers = [Feeder()]
      let messages = run(bytes, chunk: chunk)
      XCTAssertEqual(messages.map(\.count), sizes, "chunk \(chunk)")
      for (i, message) in messages.enumerated() {
        XCTAssertTrue(message.allSatisfy { $0 == UInt8(i + 1) }, "chunk \(chunk), message \(i) has the wrong bytes")
      }
    }
  }

  func testManySmallFramesPastTheCompactionThreshold() {
    var bytes = Data()
    for i in 0..<3_000 { bytes.append(frame(5, fill: UInt8(i % 250 + 1))) }
    let messages = run(bytes, chunk: 4_096)
    XCTAssertEqual(messages.count, 3_000)
    XCTAssertEqual(messages[2_999].first, UInt8(2_999 % 250 + 1))
  }

  func testLargeFrameAcrossManyReads() {
    let bytes = frame(400_000, fill: 9) + frame(10, fill: 2)
    let messages = run(bytes, chunk: 4_096)
    XCTAssertEqual(messages.map(\.count), [400_000, 10])
  }
}

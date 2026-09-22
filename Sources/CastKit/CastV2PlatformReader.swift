import Foundation

/// Reads CASTV2 frames — a 4-byte big-endian length, then that many bytes
/// of protobuf — off an input stream, in whatever pieces they arrive.
///
/// The buffer is a plain byte array. It used to be a `Data` that was
/// compacted with `removeFirst`, after which its indices no longer began
/// at zero while the reader went on counting from zero — and the first
/// batch of messages to pass the compaction threshold (a queue status
/// with a few long URLs will do it) trapped in `subdata(in:)`.
final class CastV2PlatformReader {
  let stream: InputStream

  private var buffer: [UInt8] = []
  private var readPosition = 0
  private let lock = NSLock()

  /// Bytes already consumed are dropped once they pile up this far.
  private let compactionThreshold = 8_192
  /// A frame larger than this is not a Cast message; the connection is
  /// out of sync and gets a clean slate.
  private let maxPayloadSize = 1_048_576

  init(stream: InputStream) {
    self.stream = stream
  }

  func readStream() {
    readAll(from: stream)
  }

  /// Reads everything `source` has available into the buffer.
  func readAll(from source: InputStream) {
    lock.lock()
    defer { lock.unlock() }

    var chunk = [UInt8](repeating: 0, count: 4_096)
    while source.hasBytesAvailable {
      let bytesRead = source.read(&chunk, maxLength: chunk.count)
      if bytesRead <= 0 { break }
      buffer.append(contentsOf: chunk[0..<bytesRead])
    }
  }

  func nextMessage() -> Data? {
    lock.lock()
    defer { lock.unlock() }

    let headerSize = 4
    guard buffer.count - readPosition >= headerSize else { return nil }

    let p = readPosition
    let payloadSize = Int(UInt32(buffer[p]) << 24 | UInt32(buffer[p + 1]) << 16 | UInt32(buffer[p + 2]) << 8 | UInt32(buffer[p + 3]))

    guard payloadSize <= maxPayloadSize else {
      buffer.removeAll(keepingCapacity: true)
      readPosition = 0
      return nil
    }

    guard buffer.count - readPosition >= headerSize + payloadSize else { return nil }

    let start = readPosition + headerSize
    let payload = Data(buffer[start..<(start + payloadSize)])
    readPosition = start + payloadSize

    compactIfNeeded()

    return payload
  }

  private func compactIfNeeded() {
    if readPosition == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      readPosition = 0
    } else if readPosition >= compactionThreshold {
      buffer.removeFirst(readPosition)
      readPosition = 0
    }
  }
}

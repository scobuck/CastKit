import Foundation

private let maxBufferLength = 8192

class CastV2PlatformReader {
  let stream: InputStream
  var readPosition = 0
  var buffer = Data(capacity: maxBufferLength)

  init(stream: InputStream) {
    self.stream = stream
  }

  func readStream() {
    objc_sync_enter(self)
    defer { objc_sync_exit(self) }

    let bufferSize = 32

    while stream.hasBytesAvailable {
      var bytes = [UInt8](repeating: 0, count: bufferSize)

      let bytesRead = stream.read(&bytes, maxLength: bufferSize)

      if bytesRead < 0 { continue }

      buffer.append(contentsOf: bytes.prefix(bytesRead))
    }
  }

  func nextMessage() -> Data? {
    objc_sync_enter(self)
    defer { objc_sync_exit(self) }

    let headerSize = MemoryLayout<UInt32>.size
    guard buffer.count - readPosition >= headerSize else { return nil }

    let header: UInt32 = buffer.withUnsafeBytes { rawBuffer in
      rawBuffer.loadUnaligned(fromByteOffset: readPosition, as: UInt32.self)
    }

    let payloadSize = Int(CFSwapInt32BigToHost(header))

    let maxPayloadSize = 1_048_576 // 1 MB
    guard payloadSize <= maxPayloadSize else {
      // Skip this oversized message
      buffer.removeAll()
      readPosition = 0
      return nil
    }

    readPosition += headerSize

    guard buffer.count >= readPosition + payloadSize, payloadSize >= 0 else {
      readPosition -= headerSize
      return nil
    }

    let payload = buffer.subdata(in: readPosition..<(readPosition + payloadSize))
    readPosition += payloadSize

    resetBufferIfNeeded()

    return payload
  }

  private func resetBufferIfNeeded() {
    guard buffer.count >= maxBufferLength else { return }

    if readPosition == buffer.count {
      buffer = Data(capacity: maxBufferLength)
    } else {
      buffer = Data(buffer[readPosition...])
    }

    readPosition = 0
  }
}

import Foundation
import os
import SwiftProtobuf
// SwiftyJSON is vendored in the same module

public enum CastPayload {
  case json([String: Any])
  case data(Data)

  init(_ json: [String: Any]) {
    self = .json(json)
  }

  init(_ data: Data) {
    self = .data(data)
  }
}

public typealias CastResponseHandler = @Sendable (Result<JSON, CastError>) -> Void

public enum CastError: Error, Sendable {
  case connection(String)
  case write(String)
  case session(String)
  case request(String)
  case launch(String)
  case load(String)
}

public class CastRequest: NSObject, @unchecked Sendable {
  var id: Int
  var namespace: String
  var destinationId: String
  var payload: CastPayload

  init(id: Int, namespace: String, destinationId: String, payload: [String: Any]) {
    self.id = id
    self.namespace = namespace
    self.destinationId = destinationId
    self.payload = CastPayload(payload)
  }

  init(id: Int, namespace: String, destinationId: String, payload: Data) {
    self.id = id
    self.namespace = namespace
    self.destinationId = destinationId
    self.payload = CastPayload(payload)
  }
}

public protocol CastClientDelegate: AnyObject {

  func castClient(_ client: CastClient, willConnectTo device: CastDevice)
  func castClient(_ client: CastClient, didConnectTo device: CastDevice)
  func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice)
  func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?)

  func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus)
  func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus)

}

// Default implementations so all methods are optional
public extension CastClientDelegate {
  func castClient(_ client: CastClient, willConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {}
  func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {}
  func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {}
  func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {}
}

public final class CastClient: NSObject, RequestDispatchable, Channelable, @unchecked Sendable {

  public let device: CastDevice
  public weak var delegate: CastClientDelegate?
  public var connectedApp: CastApp?

  public private(set) var currentStatus: CastStatus? {
    didSet {
      guard let status = currentStatus else { return }

      if oldValue != status {
        DispatchQueue.main.async {
          self.delegate?.castClient(self, deviceStatusDidChange: status)
          self.statusDidChange?(status)
        }
      }
    }
  }

  public private(set) var currentMediaStatus: CastMediaStatus? {
    didSet {
      guard let status = currentMediaStatus else { return }

      if oldValue != status {
        DispatchQueue.main.async {
          self.delegate?.castClient(self, mediaStatusDidChange: status)
          self.mediaStatusDidChange?(status)
        }
      }
    }
  }

  public private(set) var currentMultizoneStatus: CastMultizoneStatus?

  public var statusDidChange: ((CastStatus) -> Void)?
  public var mediaStatusDidChange: ((CastMediaStatus) -> Void)?

  private var _lock = os_unfair_lock()

  private func withLock<T>(_ body: () -> T) -> T {
    os_unfair_lock_lock(&_lock)
    defer { os_unfair_lock_unlock(&_lock) }
    return body()
  }

  public init(device: CastDevice) {
    self.device = device

    super.init()
  }

  deinit {
    disconnect()
  }

  // MARK: - Socket Setup

  public var isConnected = false {
    didSet {
      if oldValue != isConnected {
        if isConnected {
          DispatchQueue.main.async { self.delegate?.castClient(self, didConnectTo: self.device) }
        } else {
          DispatchQueue.main.async { self.delegate?.castClient(self, didDisconnectFrom: self.device) }
        }
      }
    }
  }

  private var inputStream: InputStream! {
    didSet {
      if let inputStream = inputStream {
        reader = CastV2PlatformReader(stream: inputStream)
      } else {
        reader = nil
      }
    }
  }

  private var outputStream: OutputStream!
  private var streamRunLoop: CFRunLoop?

  fileprivate lazy var socketQueue = DispatchQueue.global(qos: .userInitiated)

  public func connect() {
    socketQueue.async {
      do {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        let settings: [String: Any] = [
          kCFStreamSSLValidatesCertificateChain as String: false,
          kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
          kCFStreamPropertyShouldCloseNativeSocket as String: true
        ]

        CFStreamCreatePairWithSocketToHost(nil, self.device.hostName as CFString, UInt32(self.device.port), &readStream, &writeStream)

        guard let readStreamRetained = readStream?.takeRetainedValue() else {
          throw CastError.connection("Unable to create input stream")
        }

        guard let writeStreamRetained = writeStream?.takeRetainedValue() else {
          throw CastError.connection("Unable to create output stream")
        }

        DispatchQueue.main.async { self.delegate?.castClient(self, willConnectTo: self.device) }

        CFReadStreamSetProperty(readStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)
        CFWriteStreamSetProperty(writeStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)

        self.inputStream = readStreamRetained
        self.outputStream = writeStreamRetained

        self.inputStream.delegate = self

        self.inputStream.schedule(in: .current, forMode: .default)
        self.outputStream.schedule(in: .current, forMode: .default)

        self.inputStream.open()
        self.outputStream.open()

        self.streamRunLoop = CFRunLoopGetCurrent()
        // Blocks this GCD thread to receive stream events. The heartbeat
        // channel's disconnect timer serves as the connection watchdog and
        // will call disconnect() (which stops this run loop) on timeout.
        RunLoop.current.run()
      } catch {
        DispatchQueue.main.async { self.delegate?.castClient(self, connectionTo: self.device, didFailWith: error as NSError) }
      }
    }
  }

  public func disconnect() {
    if isConnected {
      isConnected = false
    }

    let handlers = withLock {
      let h = responseHandlers
      responseHandlers.removeAll()
      return h
    }
    for (_, entry) in handlers {
      entry.timeout.cancel()
    }

    withLock { channels }.values.forEach(remove)

    if let runLoop = streamRunLoop {
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        if self.inputStream != nil {
          self.inputStream.close()
          self.inputStream.remove(from: RunLoop.current, forMode: .default)
          self.inputStream = nil
        }

        if self.outputStream != nil {
          self.outputStream.close()
          self.outputStream.remove(from: RunLoop.current, forMode: .default)
          self.outputStream = nil
        }

        CFRunLoopStop(CFRunLoopGetCurrent())
      }
      CFRunLoopWakeUp(runLoop)
      streamRunLoop = nil
    }
  }

  // MARK: - Socket Lifecycle

  private func write(data: Data) throws {
    var payloadSize = UInt32(data.count).bigEndian
    var packet = withUnsafeBytes(of: &payloadSize) { Data($0) }
    packet.append(data)

    var totalWritten = 0
    while totalWritten < packet.count {
      let written = packet.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        return outputStream.write(bytes.baseAddress! + totalWritten, maxLength: packet.count - totalWritten)
      }
      if written < 0 {
        throw CastError.write("Failed to write to stream")
      }
      if written == 0 {
        throw CastError.write("Stream unexpectedly closed")
      }
      totalWritten += written
    }
  }


  fileprivate func sendConnectMessage() throws {
    guard outputStream != nil else { return }

    _ = connectionChannel
    _ = receiverControlChannel
    _ = mediaControlChannel
    _ = heartbeatChannel

    if device.capabilities.contains(.multizoneGroup) {
      _ = multizoneControlChannel
    }
  }

  private var reader: CastV2PlatformReader?

  fileprivate func readStream() {
    do {
      reader?.readStream()

      var pendingResponses = [(Int, Result<JSON, CastError>)]()

      while let payload = reader?.nextMessage() {
        let message = try CastMessage(serializedData: payload)

        guard let channel = withLock({ channels[message.namespace] }) else { return }

        switch message.payloadType {
        case .string:
          let json = JSON(parseJSON: message.payloadUtf8)

          channel.handleResponse(json,
                                 sourceId: message.sourceID)

          if let requestId = json[CastJSONPayloadKeys.requestId].int {
            pendingResponses.append((requestId, .success(json)))
          }
        case .binary:
          channel.handleResponse(message.payloadBinary,
                                 sourceId: message.sourceID)
        }
      }

      if !pendingResponses.isEmpty {
        let entriesToDispatch: [(CastResponseHandler, Result<JSON, CastError>)] = pendingResponses.compactMap { (requestId, result) in
          let entry = withLock { self.responseHandlers.removeValue(forKey: requestId) }
          entry?.timeout.cancel()
          guard let handler = entry?.handler else { return nil }
          return (handler, result)
        }

        if !entriesToDispatch.isEmpty {
          DispatchQueue.main.async {
            for (handler, result) in entriesToDispatch {
              handler(result)
            }
          }
        }
      }
    } catch {
      #if DEBUG
      print("CastClient: Failed to parse message: \(error)")
      #endif
    }
  }

  //MARK: - Channelable

  var channels = [String: CastChannel]()

  private lazy var heartbeatChannel: HeartbeatChannel = {
    let channel = HeartbeatChannel()
    self.add(channel: channel)

    return channel
  }()

  private lazy var connectionChannel: DeviceConnectionChannel = {
    let channel = DeviceConnectionChannel()
    self.add(channel: channel)

    return channel
  }()

  private lazy var receiverControlChannel: ReceiverControlChannel = {
    let channel = ReceiverControlChannel()
    self.add(channel: channel)

    return channel
  }()

  private lazy var mediaControlChannel: MediaControlChannel = {
    let channel = MediaControlChannel()
    self.add(channel: channel)

    return channel
  }()

  private lazy var multizoneControlChannel: MultizoneControlChannel = {
    let channel = MultizoneControlChannel()
    self.add(channel: channel)

    return channel
  }()

  // MARK: - Request response

  private lazy var currentRequestId = Int(arc4random_uniform(800))

  func nextRequestId() -> Int {
    return withLock {
      currentRequestId += 1
      return currentRequestId
    }
  }

  private let senderName: String = "sender-\(UUID().uuidString)"

  private var responseHandlers = [Int: (handler: CastResponseHandler, timeout: DispatchWorkItem)]()

  func send(_ request: CastRequest, response: CastResponseHandler?) {
    if let response = response {
      let timeoutWork = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        let handler = self.withLock { self.responseHandlers.removeValue(forKey: request.id)?.handler }
        if let handler = handler {
          DispatchQueue.main.async {
            handler(.failure(.request("Request timed out")))
          }
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)
      withLock { responseHandlers[request.id] = (handler: response, timeout: timeoutWork) }
    }

    let requestId = request.id
    do {
      let messageData = try CastMessage.encodedMessage(payload: request.payload,
                                                       namespace: request.namespace,
                                                       sourceId: senderName,
                                                       destinationId: request.destinationId)

      if let runLoop = streamRunLoop {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
          do {
            try self.write(data: messageData)
          } catch {
            self.callResponseHandler(for: requestId, with: .failure(.request(error.localizedDescription)))
          }
        }
        CFRunLoopWakeUp(runLoop)
      } else {
        try write(data: messageData)
      }
    } catch {
      callResponseHandler(for: requestId, with: .failure(.request(error.localizedDescription)))
    }
  }

  private func callResponseHandler(for requestId: Int, with result: Result<JSON, CastError>) {
    let entry = withLock { self.responseHandlers.removeValue(forKey: requestId) }
    entry?.timeout.cancel()
    if let handler = entry?.handler {
      DispatchQueue.main.async {
        handler(result)
      }
    }
  }

  // MARK: - Public messages

  public func getAppAvailability(apps: [CastApp], completion: @escaping @Sendable (Result<AppAvailability, CastError>) -> Void) {
    guard outputStream != nil else { return }

    receiverControlChannel.getAppAvailability(apps: apps, completion: completion)
  }

  public func join(app: CastApp? = nil, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    guard outputStream != nil,
      let target = app ?? currentStatus?.apps.first else {
      completion(.failure(CastError.session("No Apps Running")))
      return
    }

    if target == connectedApp {
      completion(.success(target))
    } else if let existing = currentStatus?.apps.first(where: { $0.id == target.id }) {
      connect(to: existing)
      completion(.success(existing))
    } else {
      receiverControlChannel.requestStatus { [weak self] result in
        switch result {
        case .success(let status):
          guard let app = status.apps.first else {
            completion(.failure(CastError.launch("Unable to get launched app instance")))
            return
          }

          self?.connect(to: app)
          completion(.success(app))

        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  public func launch(appId: String, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    guard outputStream != nil else { return }

    receiverControlChannel.launch(appId: appId) { [weak self] result in
      switch result {
      case .success(let app):
        self?.connect(to: app)
        fallthrough

      default:
        completion(result)
      }
    }
  }

  public func stopCurrentApp() {
    guard outputStream != nil, let app = currentStatus?.apps.first else { return }

    receiverControlChannel.stop(app: app)
  }

  public func leave(_ app: CastApp) {
    guard outputStream != nil else { return }

    connectionChannel.leave(app)
    connectedApp = nil
  }

  public func load(media: CastMedia, with app: CastApp, completion: @escaping @Sendable (Result<CastMediaStatus, CastError>) -> Void) {
    guard outputStream != nil else { return }

    mediaControlChannel.load(media: media, with: app, completion: completion)
  }

  public func requestMediaStatus(for app: CastApp, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    guard outputStream != nil else { return }

    mediaControlChannel.requestMediaStatus(for: app)
  }

  private func connect(to app: CastApp) {
    guard outputStream != nil else { return }

    connectionChannel.connect(to: app)
    connectedApp = app
  }

  public func pause() {
    guard outputStream != nil, let app = connectedApp else { return }

    if let mediaStatus = currentMediaStatus {
      mediaControlChannel.sendPause(for: app, mediaSessionId: mediaStatus.mediaSessionId)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { result in
        switch result {
        case .success(let mediaStatus):
          self.mediaControlChannel.sendPause(for: app, mediaSessionId: mediaStatus.mediaSessionId)

        case .failure(let error):
          #if DEBUG
          print(error)
          #endif
        }
      }
    }
  }

  public func play() {
    guard outputStream != nil, let app = connectedApp else { return }

    if let mediaStatus = currentMediaStatus {
      mediaControlChannel.sendPlay(for: app, mediaSessionId: mediaStatus.mediaSessionId)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { result in
        switch result {
        case .success(let mediaStatus):
          self.mediaControlChannel.sendPlay(for: app, mediaSessionId: mediaStatus.mediaSessionId)

        case .failure(let error):
          #if DEBUG
          print(error)
          #endif
        }
      }
    }
  }

  public func stop() {
    guard outputStream != nil, let app = connectedApp else { return }

    if let mediaStatus = currentMediaStatus {
      mediaControlChannel.sendStop(for: app, mediaSessionId: mediaStatus.mediaSessionId)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { result in
        switch result {
        case .success(let mediaStatus):
          self.mediaControlChannel.sendStop(for: app, mediaSessionId: mediaStatus.mediaSessionId)

        case .failure(let error):
          #if DEBUG
          print(error)
          #endif
        }
      }
    }
  }

  public func seek(to currentTime: Float) {
    guard outputStream != nil, let app = connectedApp else { return }

    if let mediaStatus = currentMediaStatus {
      mediaControlChannel.sendSeek(to: currentTime, for: app, mediaSessionId: mediaStatus.mediaSessionId)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { result in
        switch result {
        case .success(let mediaStatus):
          self.mediaControlChannel.sendSeek(to: currentTime, for: app, mediaSessionId: mediaStatus.mediaSessionId)

        case .failure(let error):
          #if DEBUG
          print(error)
          #endif
        }
      }
    }
  }

  public func setVolume(_ volume: Float) {
    guard outputStream != nil else { return }

    receiverControlChannel.setVolume(volume)
  }

  public func setMuted(_ muted: Bool) {
    guard outputStream != nil else { return }

    receiverControlChannel.setMuted(muted)
  }

  public func setVolume(_ volume: Float, for device: CastMultizoneDevice) {
    guard device.capabilities.contains(.multizoneGroup) else {
      #if DEBUG
      print("Attempted to set zone volume on non-multizone device")
      #endif
      return
    }

    multizoneControlChannel.setVolume(volume, for: device)
  }

  public func setMuted(_ isMuted: Bool, for device: CastMultizoneDevice) {
    guard device.capabilities.contains(.multizoneGroup) else {
      #if DEBUG
      print("Attempted to mute zone on non-multizone device")
      #endif
      return
    }

    multizoneControlChannel.setMuted(isMuted, for: device)
  }
}

extension CastClient: StreamDelegate {
  public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case Stream.Event.openCompleted:
      guard !isConnected else { return }
      do {
        try self.sendConnectMessage()
        self.isConnected = true
      } catch { }
    case Stream.Event.errorOccurred:
      let streamError = aStream.streamError
      DispatchQueue.main.async {
        self.delegate?.castClient(self, connectionTo: self.device, didFailWith: streamError)
      }
    case Stream.Event.hasBytesAvailable:
      self.readStream()
    case Stream.Event.endEncountered:
      disconnect()
    default:
      break
    }
  }
}

extension CastClient: ReceiverControlChannelDelegate {
  func channel(_ channel: ReceiverControlChannel, didReceive status: CastStatus) {
    currentStatus = status
  }
}

extension CastClient: MediaControlChannelDelegate {
  func channel(_ channel: MediaControlChannel, didReceive mediaStatus: CastMediaStatus) {
    currentMediaStatus = mediaStatus
  }
}

extension CastClient: HeartbeatChannelDelegate {
  func channelDidConnect(_ channel: HeartbeatChannel) {
    if !isConnected {
      isConnected = true
    }
  }

  func channelDidTimeout(_ channel: HeartbeatChannel) {
    disconnect()
    currentStatus = nil
    currentMediaStatus = nil
    connectedApp = nil
  }
}

extension CastClient: MultizoneControlChannelDelegate {
  func channel(_ channel: MultizoneControlChannel, added device: CastMultizoneDevice) {

  }

  func channel(_ channel: MultizoneControlChannel, updated device: CastMultizoneDevice) {

  }

  func channel(_ channel: MultizoneControlChannel, removed deviceId: String) {

  }

  func channel(_ channel: MultizoneControlChannel, didReceive status: CastMultizoneStatus) {
    currentMultizoneStatus = status
  }
}

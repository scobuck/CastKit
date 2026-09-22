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
  /// The receiver answered a request with a rejection or failure. `type`
  /// is the receiver's message type (LOAD_FAILED, INVALID_REQUEST, …) and
  /// `reason` its own reason string, when it gave one.
  case rejected(type: String, reason: String?)
  /// The request could not be sent: there is no open connection.
  case notConnected
  /// The receiver didn't answer in time.
  case timeout
  /// The connection was closed while the request was outstanding.
  case disconnected
}

extension CastError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .connection(let s): return "connection: \(s)"
    case .write(let s): return "write: \(s)"
    case .session(let s): return "session: \(s)"
    case .request(let s): return "request: \(s)"
    case .launch(let s): return "launch: \(s)"
    case .load(let s): return "load: \(s)"
    case .rejected(let type, let reason): return "\(type)\(reason.map { " (\($0))" } ?? "")"
    case .notConnected: return "not connected"
    case .timeout: return "timed out"
    case .disconnected: return "disconnected"
    }
  }
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
  /// The receiver reported that there is no media session any more.
  func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int)
  /// The receiver app this client had joined is gone — it quit, idled out,
  /// or another sender replaced it. The connection to the device is still up.
  func castClient(_ client: CastClient, appSessionDidEnd app: CastApp)
  /// The receiver reported a media failure on its own, outside any request.
  func castClient(_ client: CastClient, mediaDidFail error: CastError)

}

// Default implementations so all methods are optional
public extension CastClientDelegate {
  func castClient(_ client: CastClient, willConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {}
  func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {}
  func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {}
  func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {}
  func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int) {}
  func castClient(_ client: CastClient, appSessionDidEnd app: CastApp) {}
  func castClient(_ client: CastClient, mediaDidFail error: CastError) {}
}

public final class CastClient: NSObject, RequestDispatchable, Channelable, @unchecked Sendable {

  public let device: CastDevice
  public weak var delegate: CastClientDelegate?
  public private(set) var connectedApp: CastApp?

  /// Receivers speak TLS with a self-signed certificate. Tests speak plain
  /// TCP to a receiver of their own on the loopback interface.
  public var usesTLS = true
  /// How long the receiver has to answer the first CONNECT before the
  /// attempt is given up. A socket that opens but never speaks — a stale
  /// address, a device on another network — used to count as connected.
  public var connectTimeout: TimeInterval = 10

  public private(set) var currentStatus: CastStatus? {
    didSet {
      guard let status = currentStatus else { return }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, deviceStatusDidChange: status)
        self.statusDidChange?(status)
      }
    }
  }

  public private(set) var currentMediaStatus: CastMediaStatus? {
    didSet {
      guard let status = currentMediaStatus else { return }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, mediaStatusDidChange: status)
        self.mediaStatusDidChange?(status)
      }
    }
  }

  public private(set) var currentMultizoneStatus: CastMultizoneStatus?

  public var statusDidChange: ((CastStatus) -> Void)?
  public var mediaStatusDidChange: ((CastMediaStatus) -> Void)?

  private let lock = NSLock()

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
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

  public private(set) var isConnected = false {
    didSet {
      if oldValue != isConnected {
        if isConnected {
          connectWatchdog?.cancel()
          connectWatchdog = nil
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.castClient(self, didConnectTo: self.device)
          }
        } else {
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.castClient(self, didDisconnectFrom: self.device)
          }
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
  private var connectWatchdog: DispatchWorkItem?
  private var isConnecting = false
  private var channelsAttached = false

  public func connect() {
    let alreadyStarted: Bool = withLock {
      if isConnecting || streamRunLoop != nil { return true }
      isConnecting = true
      return false
    }
    guard !alreadyStarted else { return }

    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, !self.isConnected else { return }
      self.failConnection(with: CastError.timeout)
    }
    connectWatchdog = watchdog
    DispatchQueue.global().asyncAfter(deadline: .now() + connectTimeout, execute: watchdog)

    // A thread of its own, not a pooled GCD worker: the run loop below
    // blocks it for the life of the connection.
    let thread = Thread { [self] in
      self.runSocketLoop()
    }
    thread.name = "CastKit.socket"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  private func runSocketLoop() {
    do {
      var readStream: Unmanaged<CFReadStream>?
      var writeStream: Unmanaged<CFWriteStream>?

      CFStreamCreatePairWithSocketToHost(nil, self.device.hostName as CFString, UInt32(self.device.port), &readStream, &writeStream)

      guard let readStreamRetained = readStream?.takeRetainedValue() else {
        throw CastError.connection("Unable to create input stream")
      }

      guard let writeStreamRetained = writeStream?.takeRetainedValue() else {
        throw CastError.connection("Unable to create output stream")
      }

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, willConnectTo: self.device)
      }

      if usesTLS {
        let settings: [String: Any] = [
          kCFStreamSSLValidatesCertificateChain as String: false,
          kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
        ]
        CFReadStreamSetProperty(readStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)
        CFWriteStreamSetProperty(writeStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)
      }

      self.inputStream = readStreamRetained
      self.outputStream = writeStreamRetained

      self.inputStream.delegate = self

      self.inputStream.schedule(in: .current, forMode: .default)
      self.outputStream.schedule(in: .current, forMode: .default)

      self.inputStream.open()
      self.outputStream.open()

      self.streamRunLoop = CFRunLoopGetCurrent()
      withLock { isConnecting = false }
      // Blocks this thread to receive stream events; returns once
      // disconnect() has removed the streams and stopped the loop.
      RunLoop.current.run()
    } catch {
      withLock { isConnecting = false }
      failConnection(with: error)
    }
  }

  /// The attempt is over: tell the delegate, then tear down whatever was set up.
  private func failConnection(with error: Error) {
    connectWatchdog?.cancel()
    connectWatchdog = nil
    if isConnected {
      // Established, then broken: an ordinary disconnect.
      disconnect()
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.castClient(self, connectionTo: self.device, didFailWith: error)
    }
    disconnect()
  }

  public func disconnect() {
    connectWatchdog?.cancel()
    connectWatchdog = nil

    if isConnected {
      isConnected = false
    }

    // Callers waiting on a reply are told, rather than left until their
    // timeouts — which were cancelled here, so they were never told.
    let handlers = withLock {
      let h = responseHandlers
      responseHandlers.removeAll()
      return h
    }
    for (_, entry) in handlers {
      entry.timeout.cancel()
    }
    if !handlers.isEmpty {
      DispatchQueue.main.async {
        for (_, entry) in handlers {
          entry.handler(.failure(.disconnected))
        }
      }
    }

    withLock { channels }.values.forEach(remove)
    channelsAttached = false
    connectedApp = nil

    if let runLoop = streamRunLoop {
      streamRunLoop = nil
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
    }
    withLock { isConnecting = false }
  }

  // MARK: - Socket Lifecycle

  private func write(data: Data) throws {
    guard let outputStream = outputStream else {
      throw CastError.write("Output stream is nil")
    }

    var payloadSize = UInt32(data.count).bigEndian
    var packet = withUnsafeBytes(of: &payloadSize) { Data($0) }
    packet.append(data)

    var totalWritten = 0
    while totalWritten < packet.count {
      let written = packet.withUnsafeBytes { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        guard let baseAddress = bytes.baseAddress else { return -1 }
        return outputStream.write(baseAddress + totalWritten, maxLength: packet.count - totalWritten)
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

  /// Attaches the channels; each one introduces itself as it attaches
  /// (CONNECT, GET_STATUS, PING).
  fileprivate func attachChannels() {
    guard outputStream != nil, !channelsAttached else { return }
    channelsAttached = true

    add(channel: connectionChannel)
    add(channel: receiverControlChannel)
    add(channel: mediaControlChannel)
    add(channel: heartbeatChannel)

    if device.capabilities.contains(.multizoneGroup) {
      add(channel: multizoneControlChannel)
    }
  }

  private var reader: CastV2PlatformReader?

  fileprivate func readStream() {
    reader?.readStream()

    var pendingResponses = [(Int, Result<JSON, CastError>)]()

    while let payload = reader?.nextMessage() {
      let message: CastMessage
      do {
        message = try CastMessage(serializedData: payload)
      } catch {
        // One bad frame is one bad frame; the ones behind it are fine.
        #if DEBUG
        print("[CastKit] Failed to parse message: \(error)")
        #endif
        continue
      }

      // Receivers also talk on namespaces this client never registers
      // (Nest devices especially). Those messages are skipped, not the
      // rest of the batch — a `return` here left later messages and their
      // waiting callers stranded.
      guard let channel = withLock({ channels[message.namespace] }) else { continue }

      switch message.payloadType {
      case .string:
        let json = JSON(parseJSON: message.payloadUtf8)

        channel.handleResponse(json,
                               sourceId: message.sourceID)

        if let requestId = json[CastJSONPayloadKeys.requestId].int, requestId != 0 {
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
  }

  //MARK: - Channelable

  var channels = [String: CastChannel]()

  /// The channel table is read on the socket thread and changed from
  /// whichever thread connects or disconnects, so both sides take the lock.
  func add(channel: CastChannel) {
    let added: Bool = withLock {
      guard channels[channel.namespace] == nil else { return false }
      channels[channel.namespace] = channel
      return true
    }
    if added {
      channel.requestDispatcher = self
    }
  }

  func remove(channel: CastChannel) {
    let removed = withLock { channels.removeValue(forKey: channel.namespace) }
    removed?.requestDispatcher = nil
  }

  private let heartbeatChannel = HeartbeatChannel()
  private let connectionChannel = DeviceConnectionChannel()
  private let receiverControlChannel = ReceiverControlChannel()
  private let mediaControlChannel = MediaControlChannel()
  private let multizoneControlChannel = MultizoneControlChannel()

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
            handler(.failure(.timeout))
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

      guard let runLoop = streamRunLoop else {
        callResponseHandler(for: requestId, with: .failure(.notConnected))
        return
      }

      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        do {
          try self.write(data: messageData)
        } catch {
          self.callResponseHandler(for: requestId, with: .failure(.request(error.localizedDescription)))
        }
      }
      CFRunLoopWakeUp(runLoop)
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
    guard outputStream != nil else {
      completion(.failure(.notConnected))
      return
    }

    receiverControlChannel.getAppAvailability(apps: apps, completion: completion)
  }

  public func join(app: CastApp? = nil, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    guard outputStream != nil else {
      completion(.failure(.notConnected))
      return
    }
    guard let target = app ?? currentStatus?.apps.first else {
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
          guard let app = status.apps.first(where: { $0.id == target.id }) ?? status.apps.first else {
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
    guard outputStream != nil else {
      completion(.failure(.notConnected))
      return
    }

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

  /// Stops the receiver app this client launched or joined — not whatever
  /// app happens to be listed first, which could be another sender's.
  public func stopCurrentApp() {
    guard outputStream != nil, let app = connectedApp else { return }

    receiverControlChannel.stop(app: app)
    connectedApp = nil
    currentMediaStatus = nil
  }

  public func leave(_ app: CastApp) {
    guard outputStream != nil else { return }

    connectionChannel.leave(app)
    connectedApp = nil
  }

  public func load(media: CastMedia, with app: CastApp, completion: @escaping @Sendable (Result<CastMediaStatus, CastError>) -> Void) {
    guard outputStream != nil else {
      completion(.failure(.notConnected))
      return
    }

    mediaControlChannel.load(media: media, with: app, completion: completion)
  }

  public func requestMediaStatus(for app: CastApp, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    guard outputStream != nil else {
      completion?(.failure(.notConnected))
      return
    }

    mediaControlChannel.requestMediaStatus(for: app, completion: completion)
  }

  private func connect(to app: CastApp) {
    guard outputStream != nil else { return }

    connectionChannel.connect(to: app)
    connectedApp = app
  }

  /// Runs `command` with the current media session, fetching the status
  /// first if none is known yet.
  private func withMediaSession(completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)?,
                                _ command: @escaping @Sendable (CastApp, Int) -> Void) {
    guard outputStream != nil, let app = connectedApp else {
      completion?(.failure(.notConnected))
      return
    }

    if let mediaStatus = currentMediaStatus, mediaStatus.hasMediaSession {
      command(app, mediaStatus.mediaSessionId)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { result in
        switch result {
        case .success(let mediaStatus):
          command(app, mediaStatus.mediaSessionId)

        case .failure(let error):
          completion?(.failure(error))
        }
      }
    }
  }

  public func pause(completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendPause(for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func play(completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendPlay(for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func stop(completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendStop(for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func seek(to currentTime: Float, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendSeek(to: currentTime, for: app, mediaSessionId: sessionId, completion: completion)
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
      // The socket is open; "connected" waits for the receiver's first
      // word (its status, or a heartbeat).
      attachChannels()
    case Stream.Event.errorOccurred:
      failConnection(with: aStream.streamError ?? CastError.connection("Stream error"))
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
    // The app this client joined has to still be running. Gone from the
    // list — it quit, idled out, or another sender took the device — its
    // transport id is dead, and requests to it would only time out.
    if let app = connectedApp, !status.apps.contains(where: { $0.sessionId == app.sessionId }) {
      connectedApp = nil
      currentMediaStatus = nil
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, appSessionDidEnd: app)
      }
    }
    currentStatus = status
    if !isConnected {
      isConnected = true
    }
  }
}

extension CastClient: MediaControlChannelDelegate {
  func channel(_ channel: MediaControlChannel, didReceive mediaStatus: CastMediaStatus) {
    currentMediaStatus = mediaStatus
  }

  func channelDidReportNoMediaSession(_ channel: MediaControlChannel) {
    let ended = currentMediaStatus?.mediaSessionId ?? 0
    currentMediaStatus = nil
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.castClient(self, mediaSessionDidEnd: ended)
    }
  }

  func channel(_ channel: MediaControlChannel, didReceiveError error: CastError) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.castClient(self, mediaDidFail: error)
    }
  }
}

extension CastClient: DeviceConnectionChannelDelegate {
  func channel(_ channel: DeviceConnectionChannel, didReceiveCloseFrom sourceId: String) {
    if sourceId == CastConstants.receiver {
      disconnect()
    } else if let app = connectedApp, sourceId == app.transportId {
      connectedApp = nil
      currentMediaStatus = nil
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, appSessionDidEnd: app)
      }
    }
  }
}

extension CastClient: HeartbeatChannelDelegate {
  func channelDidConnect(_ channel: HeartbeatChannel) {
    if !isConnected {
      isConnected = true
    }
  }

  func channelDidTimeout(_ channel: HeartbeatChannel) {
    currentStatus = nil
    currentMediaStatus = nil
    if isConnected {
      disconnect()
    } else {
      failConnection(with: CastError.timeout)
    }
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

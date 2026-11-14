import Foundation
import os
import Security
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
  /// The receiver didn't prove it is a genuine Google Cast device. Cast
  /// device authentication runs on every connection before anything is sent;
  /// this receiver failed it, so nothing was sent to it and the connection
  /// was closed. `reason` says which check failed.
  case deviceAuthenticationFailed(reason: String)
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
    case .deviceAuthenticationFailed(let reason): return "device authentication failed: \(reason)"
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
  /// The receiver's queue changed: these are the item ids it now holds.
  func castClient(_ client: CastClient, queueChanged itemIds: [Int], changeType: String)
  /// The receiver app sent a message of its own on a namespace the app registered
  /// (`addNamespace`), not as a reply to a request.
  func castClient(_ client: CastClient, didReceiveMessage text: String, namespace: String, from sourceId: String)

}

// Default implementations so all methods are optional
public extension CastClientDelegate {
  func castClient(_ client: CastClient, didReceiveMessage text: String, namespace: String, from sourceId: String) {}
  func castClient(_ client: CastClient, willConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didConnectTo device: CastDevice) {}
  func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {}
  func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {}
  func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {}
  func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {}
  func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int) {}
  func castClient(_ client: CastClient, appSessionDidEnd app: CastApp) {}
  func castClient(_ client: CastClient, mediaDidFail error: CastError) {}
  func castClient(_ client: CastClient, queueChanged itemIds: [Int], changeType: String) {}
}

public final class CastClient: NSObject, RequestDispatchable, Channelable, @unchecked Sendable {

  public let device: CastDevice
  public weak var delegate: CastClientDelegate?
  public private(set) var connectedApp: CastApp?

  /// Receivers speak TLS with a self-signed certificate and prove they are
  /// genuine Cast devices with device authentication over it, before
  /// anything else is sent. Tests speak plain TCP to a receiver of their own
  /// on the loopback interface, which skips both.
  var usesTLS = true
  /// Checks receivers' auth replies against Google's Cast roots; tests swap in their own.
  var deviceAuthenticator = CastDeviceAuthenticator.google
  /// Tests: authenticate over plain TCP, with this as the receiver's TLS certificate.
  var testPeerCertificate: Data?
  /// Tests: the time certificates are checked at.
  var authenticationTime: @Sendable () -> Date = { Date() }
  /// Tests against real hardware: stop once the receiver has answered the
  /// auth challenge, send nothing more, and report the outcome here.
  var authenticationOnly: (@Sendable (Result<CastDeviceAuthResult, CastError>) -> Void)?
  /// What device authentication established about this receiver; nil until it passes.
  private(set) var deviceAuthentication: CastDeviceAuthResult?

  private var requiresDeviceAuthentication: Bool { usesTLS || testPeerCertificate != nil }
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
    // The socket thread holds the client for as long as its run loop runs, so
    // there is no connection left to close here. Nothing below may reach the
    // delegate or take a weak reference: the client is being deallocated, and
    // a [weak self] now traps (disconnect() used to, when a late status had
    // marked the client connected again).
    connectWatchdog?.cancel()
    let handlers = responseHandlers
    responseHandlers.removeAll()
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
    for channel in channels.values {
      channel.requestDispatcher = nil
    }
  }

  // MARK: - Socket Setup

  public private(set) var isConnected = false {
    didSet {
      if oldValue != isConnected {
        if isConnected {
          cancelConnectWatchdog()
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

  /// One socket: its streams, the frame reader, and the run loop of the
  /// thread serving it. Each connection has its own, so one being torn down
  /// can't close, read or write the next one's streams (disconnect() used to
  /// close whatever streams the client held when its block ran, which after
  /// a quick reconnect were the new connection's).
  private final class Link: @unchecked Sendable {
    let input: InputStream
    let output: OutputStream
    let reader: CastV2PlatformReader
    let runLoop: CFRunLoop

    init(input: InputStream, output: OutputStream, runLoop: CFRunLoop) {
      self.input = input
      self.output = output
      self.runLoop = runLoop
      reader = CastV2PlatformReader(stream: input)
    }

    /// Closes the streams on the link's own thread, which then ends.
    func close() {
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
        for stream in [input, output] as [Stream] {
          stream.delegate = nil
          stream.close()
          stream.remove(from: .current, forMode: .default)
        }
        CFRunLoopStop(CFRunLoopGetCurrent())
      }
      CFRunLoopWakeUp(runLoop)
    }

    /// Writes one CASTV2 frame: a 4-byte big-endian length, then the message.
    func write(_ data: Data) throws {
      var payloadSize = UInt32(data.count).bigEndian
      var packet = withUnsafeBytes(of: &payloadSize) { Data($0) }
      packet.append(data)

      var totalWritten = 0
      while totalWritten < packet.count {
        let written = packet.withUnsafeBytes { rawBuffer in
          let bytes = rawBuffer.bindMemory(to: UInt8.self)
          guard let baseAddress = bytes.baseAddress else { return -1 }
          return output.write(baseAddress + totalWritten, maxLength: packet.count - totalWritten)
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
  }

  /// The current socket, if any.
  private var link: Link?
  private var currentLink: Link? { withLock { link } }
  /// Gives up on a connection that isn't up in time. Set and cleared from
  /// several threads, so under the lock.
  private var connectWatchdog: DispatchWorkItem?

  private func cancelConnectWatchdog() {
    let watchdog: DispatchWorkItem? = withLock {
      defer { connectWatchdog = nil }
      return connectWatchdog
    }
    watchdog?.cancel()
  }
  private var isConnecting = false
  /// Counts connection attempts, so a socket thread still starting when its
  /// attempt was dropped doesn't take over a later one.
  private var generation = 0
  /// The channels are attached once the receiver has passed device
  /// authentication (at once over plain TCP). Until then nothing but the auth
  /// challenge may be sent, and the public calls answer "not connected".
  private var channelsAttached = false
  /// A connection attempt or connection is under way and hasn't ended.
  private var attemptActive = false

  /// Where the connection is before the channels attach.
  private enum Handshake {
    /// Waiting for the socket (and TLS handshake) to open.
    case waiting
    /// The challenge is out; waiting for the receiver's reply.
    case authenticating(nonce: Data, peerCertificate: Data)
    /// Authenticated, or no authentication needed: the channels may attach.
    case done
  }
  private var handshake = Handshake.waiting

  /// Whether requests may go out: the receiver passed device authentication
  /// (or none is needed) and the channels are attached.
  private var isOpen: Bool { withLock { channelsAttached } }

  public func connect() {
    let attempt: Int? = withLock {
      if isConnecting || link != nil { return nil }
      isConnecting = true
      attemptActive = true
      handshake = .waiting
      deviceAuthentication = nil
      generation += 1
      return generation
    }
    guard let attempt else { return }

    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, !self.isConnected else { return }
      self.failConnection(with: CastError.timeout)
    }
    withLock { connectWatchdog = watchdog }
    DispatchQueue.global().asyncAfter(deadline: .now() + connectTimeout, execute: watchdog)

    // A thread of its own, not a pooled GCD worker: the run loop below
    // blocks it for the life of the connection.
    let thread = Thread { [self] in
      self.runSocketLoop(attempt: attempt)
    }
    thread.name = "CastKit.socket"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  private func runSocketLoop(attempt: Int) {
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
        // Receivers' certificates are self-signed and name no host, so the
        // chain isn't checked here. Device authentication checks the
        // receiver instead, over this TLS certificate, before anything else
        // is sent (as Chromium does: unsafely_skip_cert_verification, then
        // the auth challenge).
        let settings: [String: Any] = [
          kCFStreamSSLValidatesCertificateChain as String: false,
          kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
        ]
        CFReadStreamSetProperty(readStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)
        CFWriteStreamSetProperty(writeStreamRetained, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFTypeRef?)
      }

      let input: InputStream = readStreamRetained
      let output: OutputStream = writeStreamRetained
      let newLink = Link(input: input, output: output, runLoop: CFRunLoopGetCurrent())
      let wanted: Bool = withLock {
        guard attempt == generation, attemptActive else { return false }
        link = newLink
        isConnecting = false
        return true
      }
      guard wanted else { return }

      input.delegate = self
      // The output stream says when the socket, and the TLS handshake with
      // it, is done: the peer's certificate is there from its first
      // hasSpaceAvailable, not at openCompleted.
      output.delegate = self

      input.schedule(in: .current, forMode: .default)
      output.schedule(in: .current, forMode: .default)

      input.open()
      output.open()

      // Blocks this thread to receive stream events; returns once
      // disconnect() has closed the link's streams.
      RunLoop.current.run()
    } catch {
      let current: Bool = withLock {
        guard attempt == generation else { return false }
        isConnecting = false
        return true
      }
      if current {
        failConnection(with: error)
      }
    }
  }

  /// The attempt is over: tell the delegate (once), then tear down whatever was set up.
  private func failConnection(with error: Error) {
    cancelConnectWatchdog()
    if isConnected {
      // Established, then broken: an ordinary disconnect.
      disconnect()
      return
    }
    let report: Bool = withLock {
      defer { attemptActive = false }
      return attemptActive
    }
    if report {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.castClient(self, connectionTo: self.device, didFailWith: error)
      }
    }
    disconnect()
  }

  public func disconnect() {
    cancelConnectWatchdog()

    // Detach first, so a status already on its way in can't mark the client
    // connected again after this, and a write queued for this socket finds
    // it gone.
    let closing: Link? = withLock {
      attemptActive = false
      handshake = .waiting
      channelsAttached = false
      isConnecting = false
      defer { link = nil }
      return link
    }

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
    connectedApp = nil

    closing?.close()
  }

  // MARK: - Socket Lifecycle

  /// The socket (and its TLS handshake) is open: authenticate the receiver,
  /// or, over plain TCP, attach the channels at once. Runs on the socket thread.
  private func socketDidOpen(_ link: Link) {
    let proceed: Bool = withLock {
      guard self.link === link, attemptActive, case .waiting = handshake else { return false }
      if !requiresDeviceAuthentication { handshake = .done }
      return true
    }
    guard proceed else { return }
    guard requiresDeviceAuthentication else {
      attachChannels()
      return
    }

    guard let peerCertificate = testPeerCertificate ?? tlsPeerCertificate(of: link) else {
      authenticationDidFinish(.failure(.noPeerCertificate))
      return
    }
    do {
      let nonce = try CastDeviceAuthenticator.makeNonce()
      let challenge = try DeviceAuthChannel.challengeMessage(nonce: nonce)
      let current: Bool = withLock {
        guard self.link === link, attemptActive else { return false }
        handshake = .authenticating(nonce: nonce, peerCertificate: peerCertificate)
        return true
      }
      guard current else { return }
      Log.auth.debug("Sending the device auth challenge to \(self.device.name, privacy: .private)")
      try link.write(challenge)
    } catch let failure as CastDeviceAuthFailure {
      authenticationDidFinish(.failure(failure))
    } catch {
      failConnection(with: error)
    }
  }

  /// The DER of the certificate the receiver presented in the TLS handshake.
  private func tlsPeerCertificate(of link: Link) -> Data? {
    guard let value = link.output.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLPeerTrust as String)) else {
      return nil
    }
    let object = value as CFTypeRef
    guard CFGetTypeID(object) == SecTrustGetTypeID() else { return nil }
    let trust = object as! SecTrust
    SecTrustSetNetworkFetchAllowed(trust, false)
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
      return nil
    }
    return SecCertificateCopyData(leaf) as Data
  }

  /// Checks the receiver's first message, which must be its auth reply.
  /// Returns whether the connection goes on. Runs on the socket thread.
  private func handleAuthReply(_ message: CastMessage, nonce: Data, peerCertificate: Data) -> Bool {
    do {
      let payload = try DeviceAuthChannel.replyPayload(message)
      let result = try deviceAuthenticator.authenticate(reply: payload, nonce: nonce, peerCertificate: peerCertificate,
                                                        deviceCapabilities: device.capabilities, at: authenticationTime())
      return authenticationDidFinish(.success(result))
    } catch let failure as CastDeviceAuthFailure {
      return authenticationDidFinish(.failure(failure))
    } catch {
      return authenticationDidFinish(.failure(.malformedReply(error.localizedDescription)))
    }
  }

  /// Opens the channels to a receiver that passed, or ends the connection to
  /// one that didn't. Returns whether the connection goes on.
  @discardableResult
  private func authenticationDidFinish(_ outcome: Result<CastDeviceAuthResult, CastDeviceAuthFailure>) -> Bool {
    switch outcome {
    case .success(let result):
      Log.auth.debug("""
        \(self.device.name, privacy: .private) authenticated: chain to \(result.rootName, privacy: .public), \
        \(result.signatureAlgorithm, privacy: .public) with \(result.hashAlgorithm, privacy: .public), \
        revocation: \(result.revocation.rawValue, privacy: .public)\(result.isAudioOnly ? ", audio only" : "", privacy: .public)
        """)
      if let report = authenticationOnly {
        report(.success(result))
        disconnect()
        return false
      }
      let proceed: Bool = withLock {
        guard attemptActive, case .authenticating = handshake else { return false }  // disconnected meanwhile
        handshake = .done
        deviceAuthentication = result
        return true
      }
      guard proceed else { return false }
      attachChannels()
      return true
    case .failure(let failure):
      Log.auth.error("\(self.device.name, privacy: .private) failed device authentication: \(failure.description, privacy: .public)")
      let error = CastError.deviceAuthenticationFailed(reason: failure.description)
      if let report = authenticationOnly {
        report(.failure(error))
        disconnect()
        return false
      }
      failConnection(with: error)
      return false
    }
  }

  /// Attaches the channels; each one introduces itself as it attaches
  /// (CONNECT, GET_STATUS, PING).
  private func attachChannels() {
    let attach: Bool = withLock {
      guard link != nil, attemptActive, case .done = handshake, !channelsAttached else { return false }
      channelsAttached = true
      return true
    }
    guard attach else { return }

    add(channel: connectionChannel)
    add(channel: receiverControlChannel)
    add(channel: mediaControlChannel)
    add(channel: heartbeatChannel)

    if device.capabilities.contains(.multizoneGroup) {
      add(channel: multizoneControlChannel)
    }
  }

  private func readStream(_ link: Link) {
    link.reader.readStream()

    var pendingResponses = [(Int, Result<JSON, CastError>)]()

    while let payload = link.reader.nextMessage() {
      let message: CastMessage
      do {
        message = try CastMessage(serializedBytes: payload)
      } catch {
        // One bad frame is one bad frame; the ones behind it are fine.
        #if DEBUG
        print("[CastKit] Failed to parse message: \(error)")
        #endif
        continue
      }

      // Until the receiver has passed device authentication, its first
      // message must be the auth reply, and nothing reaches the channels.
      switch withLock({ handshake }) {
      case .authenticating(let nonce, let peerCertificate):
        guard handleAuthReply(message, nonce: nonce, peerCertificate: peerCertificate) else { return }
        continue
      case .waiting:
        continue
      case .done:
        break
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
    // Nothing goes to a receiver that hasn't passed device authentication.
    // (The challenge itself is written directly, not through here.)
    guard case .done = withLock({ handshake }) else {
      if let response {
        DispatchQueue.main.async { response(.failure(.notConnected)) }
      }
      return
    }

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

      guard let link = currentLink else {
        callResponseHandler(for: requestId, with: .failure(.notConnected))
        return
      }

      CFRunLoopPerformBlock(link.runLoop, CFRunLoopMode.defaultMode.rawValue) {
        // Written on the socket's own thread, and only to the socket it was
        // meant for. A socket that's gone was closed by disconnect(), which
        // tells every waiting caller "disconnected".
        guard self.currentLink === link else { return }
        do {
          try link.write(messageData)
        } catch {
          self.callResponseHandler(for: requestId, with: .failure(.request(error.localizedDescription)))
        }
      }
      CFRunLoopWakeUp(link.runLoop)
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
    guard isOpen else {
      completion(.failure(.notConnected))
      return
    }

    receiverControlChannel.getAppAvailability(apps: apps, completion: completion)
  }

  public func join(app: CastApp? = nil, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    guard isOpen else {
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

  // MARK: - Custom namespaces

  /// Listens on an app's own namespace ("urn:x-cast:…"), so its receiver app's messages
  /// come to the delegate and `sendMessage` can address it. Registering twice is harmless.
  public func addNamespace(_ namespace: String) {
    guard withLock({ channels[namespace] }) == nil else { return }
    let channel = CustomChannel(namespace: namespace)
    channel.onMessage = { [weak self] text, sourceId in
      guard let self else { return }
      DispatchQueue.main.async {
        self.delegate?.castClient(self, didReceiveMessage: text, namespace: namespace, from: sourceId)
      }
    }
    add(channel: channel)
  }

  /// Sends a JSON message on a registered namespace to the receiver app this client
  /// launched or joined. With a completion, the receiver is expected to answer with the
  /// same `requestId`; the answer arrives as JSON text (30 s timeout).
  public func sendMessage(_ payload: [String: Any], namespace: String,
                          completion: (@Sendable (Result<String, CastError>) -> Void)? = nil) {
    guard isOpen, let app = connectedApp else {
      completion?(.failure(.notConnected))
      return
    }
    guard let channel = withLock({ channels[namespace] }) as? CustomChannel else {
      completion?(.failure(.request("Namespace \(namespace) isn't registered")))
      return
    }
    channel.send(payload, to: app, completion: completion)
  }

  public func launch(appId: String, completion: @escaping @Sendable (Result<CastApp, CastError>) -> Void) {
    guard isOpen else {
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
    guard isOpen, let app = connectedApp else { return }

    receiverControlChannel.stop(app: app)
    connectedApp = nil
    currentMediaStatus = nil
  }

  public func leave(_ app: CastApp) {
    guard isOpen else { return }

    connectionChannel.leave(app)
    connectedApp = nil
  }

  public func load(media: CastMedia, with app: CastApp, completion: @escaping @Sendable (Result<CastMediaStatus, CastError>) -> Void) {
    guard isOpen else {
      completion(.failure(.notConnected))
      return
    }

    mediaControlChannel.load(media: media, with: app, completion: completion)
  }

  // MARK: Queue

  public func queueLoad(items: [CastQueueItem], startIndex: Int = 0, startTime: Double = 0, repeatMode: String = "REPEAT_OFF", with app: CastApp, completion: @escaping @Sendable (Result<CastMediaStatus, CastError>) -> Void) {
    guard isOpen else {
      completion(.failure(.notConnected))
      return
    }
    mediaControlChannel.queueLoad(items: items, startIndex: startIndex, startTime: startTime, repeatMode: repeatMode, with: app, completion: completion)
  }

  public func queueInsert(items: [CastQueueItem], insertBefore: Int? = nil, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.queueInsert(items: items, insertBefore: insertBefore, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func queueRemove(itemIds: [Int], completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.queueRemove(itemIds: itemIds, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func queueJump(_ jump: Int, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.queueUpdate(jump: jump, currentItemId: nil, repeatMode: nil, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func queueItems(itemIds: [Int], completion: @escaping @Sendable (Result<[CastQueueItemStatus], CastError>) -> Void) {
    guard isOpen, let app = connectedApp else {
      completion(.failure(.notConnected))
      return
    }
    if let mediaStatus = currentMediaStatus, mediaStatus.hasMediaSession {
      mediaControlChannel.queueItems(itemIds: itemIds, for: app, mediaSessionId: mediaStatus.mediaSessionId, completion: completion)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { [weak self] result in
        switch result {
        case .success(let status):
          self?.mediaControlChannel.queueItems(itemIds: itemIds, for: app, mediaSessionId: status.mediaSessionId, completion: completion)
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  public func queueItemIds(completion: @escaping @Sendable (Result<[Int], CastError>) -> Void) {
    guard isOpen, let app = connectedApp else {
      completion(.failure(.notConnected))
      return
    }
    if let mediaStatus = currentMediaStatus, mediaStatus.hasMediaSession {
      mediaControlChannel.queueItemIds(for: app, mediaSessionId: mediaStatus.mediaSessionId, completion: completion)
    } else {
      mediaControlChannel.requestMediaStatus(for: app) { [weak self] result in
        switch result {
        case .success(let status):
          self?.mediaControlChannel.queueItemIds(for: app, mediaSessionId: status.mediaSessionId, completion: completion)
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  public func requestMediaStatus(for app: CastApp, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    guard isOpen else {
      completion?(.failure(.notConnected))
      return
    }

    mediaControlChannel.requestMediaStatus(for: app, completion: completion)
  }

  private func connect(to app: CastApp) {
    guard isOpen else { return }

    connectionChannel.connect(to: app)
    connectedApp = app
  }

  /// Runs `command` with the current media session, fetching the status
  /// first if none is known yet.
  private func withMediaSession(completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)?,
                                _ command: @escaping @Sendable (CastApp, Int) -> Void) {
    guard isOpen, let app = connectedApp else {
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
    guard isOpen else { return }

    receiverControlChannel.setVolume(volume)
  }

  /// Which tracks are on, and how text is drawn.
  public func editTracks(activeTrackIds: [Int], textTrackStyle: CastTextTrackStyle? = nil, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendEditTracks(activeTrackIds: activeTrackIds, textTrackStyle: textTrackStyle, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func setPlaybackRate(_ rate: Double, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendPlaybackRate(rate, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  /// The media's own volume (0–1), independent of the device volume.
  public func setMediaVolume(_ level: Float, muted: Bool? = nil, completion: (@Sendable (Result<CastMediaStatus, CastError>) -> Void)? = nil) {
    withMediaSession(completion: completion) { [weak self] app, sessionId in
      self?.mediaControlChannel.sendMediaVolume(level, muted: muted, for: app, mediaSessionId: sessionId, completion: completion)
    }
  }

  public func setMuted(_ muted: Bool) {
    guard isOpen else { return }

    receiverControlChannel.setMuted(muted)
  }

  public func setVolume(_ volume: Float, for device: CastMultizoneDevice) {
    guard device.capabilities.contains(.multizoneGroup) else {
      #if DEBUG
      print("Attempted to set zone volume on non-multizone device")
      #endif
      return
    }
    guard isOpen, multizoneControlChannel.requestDispatcher != nil else { return }

    multizoneControlChannel.setVolume(volume, for: device)
  }

  public func setMuted(_ isMuted: Bool, for device: CastMultizoneDevice) {
    guard device.capabilities.contains(.multizoneGroup) else {
      #if DEBUG
      print("Attempted to mute zone on non-multizone device")
      #endif
      return
    }
    guard isOpen, multizoneControlChannel.requestDispatcher != nil else { return }

    multizoneControlChannel.setMuted(isMuted, for: device)
  }
}

extension CastClient: StreamDelegate {
  public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    // The last events of a socket already torn down are not this connection's.
    guard let link = currentLink, aStream === link.input || aStream === link.output else { return }
    if aStream === link.output {
      // Only its first hasSpaceAvailable matters: the socket and the TLS
      // handshake are done. The input stream reports errors and the end.
      if eventCode == .hasSpaceAvailable {
        socketDidOpen(link)
      }
      return
    }
    switch eventCode {
    case Stream.Event.errorOccurred:
      failConnection(with: aStream.streamError ?? CastError.connection("Stream error"))
    case Stream.Event.hasBytesAvailable:
      self.readStream(link)
    case Stream.Event.endEncountered:
      if isConnected {
        disconnect()
      } else {
        // Closed before the connection was up, by a receiver that refused the
        // challenge, say: a failed attempt, not a quiet disconnect.
        failConnection(with: CastError.connection("The receiver closed the connection"))
      }
    default:
      // openCompleted: "connected" waits for the handshake, then for the
      // receiver's first word (its status, or a heartbeat).
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
    if !isConnected, isOpen {
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

  func channel(_ channel: MediaControlChannel, queueChanged itemIds: [Int], changeType: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.castClient(self, queueChanged: itemIds, changeType: changeType)
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
    if !isConnected, isOpen {
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

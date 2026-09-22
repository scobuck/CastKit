import Foundation
// SwiftyJSON is vendored in the same module

class HeartbeatChannel: CastChannel {
  private let pingInterval: TimeInterval = 5
  private let disconnectTimeout: TimeInterval = 10

  /// Timers live on their own queue rather than a run loop: they are
  /// started on the socket thread and stopped from whichever thread
  /// disconnects, which a run-loop timer does not allow.
  private let timerQueue = DispatchQueue(label: "CastKit.heartbeat")
  private var pingSource: DispatchSourceTimer?
  private var watchdog: DispatchWorkItem?

  override weak var requestDispatcher: RequestDispatchable! {
    didSet {
      if requestDispatcher != nil {
        startBeating()
      } else {
        stopBeating()
      }
    }
  }

  private var delegate: HeartbeatChannelDelegate? {
    return requestDispatcher as? HeartbeatChannelDelegate
  }

  init() {
    super.init(namespace: CastNamespace.heartbeat)
  }

  deinit {
    pingSource?.cancel()
    watchdog?.cancel()
  }

  override func handleResponse(_ json: JSON, sourceId: String) {
    delegate?.channelDidConnect(self)

    guard let rawType = json[CastJSONPayloadKeys.type].string else { return }

    guard let type = CastMessageType(rawValue: rawType) else {
      #if DEBUG
      print("[CastKit] heartbeat: unknown message type \(rawType)")
      #endif
      return
    }

    if type == .ping {
      sendPong(to: sourceId)
    }

    armWatchdog()
  }

  /// Nothing heard for the timeout means the receiver is gone. The watchdog
  /// is armed before anything has been heard, so a socket that opens but
  /// never speaks — a stale address, a device on another network — is
  /// given up on rather than held "connected" for good.
  private func armWatchdog() {
    watchdog?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.delegate?.channelDidTimeout(self)
    }
    watchdog = item
    timerQueue.asyncAfter(deadline: .now() + disconnectTimeout, execute: item)
  }

  private func startBeating() {
    armWatchdog()
    let source = DispatchSource.makeTimerSource(queue: timerQueue)
    source.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
    source.setEventHandler { [weak self] in
      self?.sendPing()
    }
    source.resume()
    pingSource = source
    sendPing()
  }

  private func stopBeating() {
    pingSource?.cancel()
    pingSource = nil
    watchdog?.cancel()
    watchdog = nil
  }

  private func sendPing() {
    guard let dispatcher = requestDispatcher else { return }
    let request = dispatcher.request(withNamespace: namespace,
                                     destinationId: CastConstants.transport,
                                     payload: [CastJSONPayloadKeys.type: CastMessageType.ping.rawValue])

    send(request)
  }

  private func sendPong(to destinationId: String) {
    guard let dispatcher = requestDispatcher else { return }
    let request = dispatcher.request(withNamespace: namespace,
                                     destinationId: destinationId,
                                     payload: [CastJSONPayloadKeys.type: CastMessageType.pong.rawValue])

    send(request)
  }
}

protocol HeartbeatChannelDelegate: AnyObject {
  func channelDidConnect(_ channel: HeartbeatChannel)
  func channelDidTimeout(_ channel: HeartbeatChannel)
}

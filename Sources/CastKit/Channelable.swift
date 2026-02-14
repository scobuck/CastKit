import Foundation

protocol Channelable: RequestDispatchable {
  var channels: [String: CastChannel] { get set }

  func add(channel: CastChannel)
  func remove(channel: CastChannel)
}

extension Channelable {
  func add(channel: CastChannel) {
    let namespace = channel.namespace
    guard channels[namespace] == nil else {
      #if DEBUG
      print("Channel already attached for \(namespace)")
      #endif
      return
    }

    channels[namespace] = channel
    channel.requestDispatcher = self
  }

  func remove(channel: CastChannel) {
    let namespace = channel.namespace
    guard let channel = channels.removeValue(forKey: namespace) else {
      #if DEBUG
      print("No channel attached for \(namespace)")
      #endif
      return
    }

    channel.requestDispatcher = nil
  }
}

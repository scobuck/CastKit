import Foundation
import os

protocol Channelable: RequestDispatchable {
  var channels: [String: CastChannel] { get set }

  func add(channel: CastChannel)
  func remove(channel: CastChannel)
}

extension Channelable {
  func add(channel: CastChannel) {
    let namespace = channel.namespace
    guard channels[namespace] == nil else {
      Log.channel.debug("channel already attached for \(namespace, privacy: .public)")
      return
    }

    channels[namespace] = channel
    channel.requestDispatcher = self
  }

  func remove(channel: CastChannel) {
    let namespace = channel.namespace
    guard let channel = channels.removeValue(forKey: namespace) else {
      Log.channel.debug("no channel attached for \(namespace, privacy: .public)")
      return
    }

    channel.requestDispatcher = nil
  }
}

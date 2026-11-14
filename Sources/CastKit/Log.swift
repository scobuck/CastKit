import os

/// CastKit's logging, under the "CastKit" subsystem. Mostly debug level,
/// which costs nothing unless someone is capturing it. Nothing logged here
/// may carry a contentId, a media URL, customData, headers or tokens; device
/// names and other device-identifying values are private.
enum Log {
  static let subsystem = "CastKit"
  /// Cast device authentication.
  static let auth = Logger(subsystem: subsystem, category: "auth")
  /// The connection to a receiver: sockets, frames.
  static let connection = Logger(subsystem: subsystem, category: "connection")
  /// Bonjour discovery of receivers.
  static let discovery = Logger(subsystem: subsystem, category: "discovery")
  /// The protocol channels (receiver, media, heartbeat, multizone, setup).
  static let channel = Logger(subsystem: subsystem, category: "channel")
  /// CastManager: loads, launches and what the receiver reports.
  static let manager = Logger(subsystem: subsystem, category: "manager")
  /// The vendored SwiftyJSON.
  static let json = Logger(subsystem: subsystem, category: "json")
}

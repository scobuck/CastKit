import os

/// CastKit's logging, under the "CastKit" subsystem. Mostly debug level,
/// which costs nothing unless someone is capturing it. Nothing logged here
/// may carry a contentId, a media URL, customData, headers or tokens; device
/// names and other device-identifying values are private.
enum Log {
  static let subsystem = "CastKit"
  /// Cast device authentication.
  static let auth = Logger(subsystem: subsystem, category: "auth")
}

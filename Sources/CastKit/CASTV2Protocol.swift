import Foundation

struct CastNamespace {
  static let auth = "urn:x-cast:com.google.cast.tp.deviceauth"
  static let connection = "urn:x-cast:com.google.cast.tp.connection"
  static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
  static let receiver = "urn:x-cast:com.google.cast.receiver"
  static let media = "urn:x-cast:com.google.cast.media"
  static let discovery = "urn:x-cast:com.google.cast.receiver.discovery"
  static let setup = "urn:x-cast:com.google.cast.setup"
  static let multizone = "urn:x-cast:com.google.cast.multizone"
}

enum CastMessageType: String {
  case ping = "PING"
  case pong = "PONG"
  case connect = "CONNECT"
  case close = "CLOSE"
  case status = "RECEIVER_STATUS"
  case launch = "LAUNCH"
  case stop = "STOP"
  case load = "LOAD"
  case pause = "PAUSE"
  case play = "PLAY"
  case seek = "SEEK"
  case setVolume = "SET_VOLUME"
  case setDeviceVolume = "SET_DEVICE_VOLUME"
  case statusRequest = "GET_STATUS"
  case availableApps = "GET_APP_AVAILABILITY"
  case mediaStatus = "MEDIA_STATUS"
  case getDeviceInfo = "GET_DEVICE_INFO"
  case deviceInfo = "DEVICE_INFO"
  case getDeviceConfig = "eureka_info"
  case setDeviceConfig = "set_eureka_info"
  case getAppDeviceId = "get_app_device_id"
  case multizoneStatus = "MULTIZONE_STATUS"
  case deviceAdded = "DEVICE_ADDED"
  case deviceUpdated = "DEVICE_UPDATED"
  case deviceRemoved = "DEVICE_REMOVED"
  case invalidRequest = "INVALID_REQUEST"
  case mdxSessionStatus = "mdxSessionStatus"
  // Error replies. The receiver answers a bad or failed request with one
  // of these instead of the status it was asked for; they used to fall
  // through as "unknown type" and the caller waited for a reply that had
  // already come.
  case loadFailed = "LOAD_FAILED"
  case loadCancelled = "LOAD_CANCELLED"
  case launchError = "LAUNCH_ERROR"
  case invalidPlayerState = "INVALID_PLAYER_STATE"
  case error = "ERROR"

  /// Whether this message is the receiver rejecting or failing a request.
  var isError: Bool {
    switch self {
    case .loadFailed, .loadCancelled, .launchError, .invalidPlayerState, .invalidRequest, .error:
      return true
    default:
      return false
    }
  }
}

struct CastJSONPayloadKeys {
  static let type = "type"
  static let requestId = "requestId"
  static let status = "status"
  static let applications = "applications"
  static let appId = "appId"
  static let displayName = "displayName"
  static let sessionId = "sessionId"
  static let transportId = "transportId"
  static let statusText = "statusText"
  static let isIdleScreen = "isIdleScreen"
  static let namespaces = "namespaces"
  static let volume = "volume"
  static let controlType = "controlType"
  static let level = "level"
  static let muted = "muted"
  static let mediaSessionId = "mediaSessionId"
  static let availability = "availability"
  static let name = "name"
  static let currentTime = "currentTime"
  static let media = "media"
  static let repeatMode = "repeatMode"
  static let autoplay = "autoplay"
  static let contentId = "contentId"
  static let contentType = "contentType"
  static let streamType = "streamType"
  static let metadata = "metadata"
  static let metadataType = "metadataType"
  static let title = "title"
  static let images = "images"
  static let url = "url"
  static let artist = "artist"
  static let activeTrackIds = "activeTrackIds"
  static let playbackRate = "playbackRate"
  static let playerState = "playerState"
  static let deviceId = "deviceId"
  static let device = "device"
  static let devices = "devices"
  static let capabilities = "capabilities"
  static let reason = "reason"
  static let idleReason = "idleReason"
  static let duration = "duration"
  static let supportedMediaCommands = "supportedMediaCommands"
  static let customData = "customData"
}

struct CastConstants {
  static let sender = "sender-0"
  static let receiver = "receiver-0"
  static let transport = "transport-0"
}

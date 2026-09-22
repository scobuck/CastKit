import Foundation
// SwiftyJSON is vendored in the same module

public enum CastMediaPlayerState: String, Sendable {
  case buffering = "BUFFERING"
  case playing = "PLAYING"
  case paused = "PAUSED"
  case stopped = "STOPPED"
  case idle = "IDLE"
}

/// Why the receiver's player went idle.
public enum CastIdleReason: String, Sendable {
  /// The media played to its end.
  case finished = "FINISHED"
  /// A sender stopped it.
  case cancelled = "CANCELLED"
  /// A new LOAD replaced it.
  case interrupted = "INTERRUPTED"
  /// The receiver could not play it.
  case error = "ERROR"
}

public final class CastMediaStatus: NSObject, @unchecked Sendable {

  public let mediaSessionId: Int
  public let playbackRate: Double
  public let playerState: CastMediaPlayerState
  /// The position the receiver reported, in seconds, at `receivedAt`.
  public let currentTime: Double
  /// The media's length in seconds, when the receiver knows it.
  public let duration: Double?
  public let contentType: String?
  public let metadata: JSON?
  public let contentID: String?
  public let idleReason: CastIdleReason?
  /// The receiver's own idle reason string, for reasons this library doesn't name.
  public let idleReasonRaw: String?
  /// Bit mask of the media commands the receiver accepts for this media.
  public let supportedMediaCommands: Int
  /// The media-level (not device) volume, when reported.
  public let volumeLevel: Double?
  public let volumeMuted: Bool?
  /// When this report arrived.
  public let receivedAt = Date()

  /// The receiver's position now, extrapolated from the report only while
  /// it is playing and capped at the media's length. A report taken while
  /// paused stays where it was — it used to run on as if playing.
  public var estimatedCurrentTime: Double {
    guard playerState == .playing else { return currentTime }
    var time = currentTime + playbackRate * Date().timeIntervalSince(receivedAt)
    if let duration, duration > 0 { time = min(time, duration) }
    return time
  }

  @available(*, deprecated, renamed: "estimatedCurrentTime")
  public var adjustedCurrentTime: Double { estimatedCurrentTime }

  public var state: String {
    return playerState.rawValue
  }

  /// A status with no media session is what the receiver sends after the
  /// media ended or was stopped; commands sent with its id are rejected.
  public var hasMediaSession: Bool { mediaSessionId != 0 }

  public override var description: String {
    return "MediaStatus(mediaSessionId: \(mediaSessionId), playbackRate: \(playbackRate), playerState: \(playerState.rawValue), currentTime: \(currentTime), duration: \(duration.map { String($0) } ?? "-"), idleReason: \(idleReasonRaw ?? "-"))"
  }

  init(json: JSON) {
    mediaSessionId = json[CastJSONPayloadKeys.mediaSessionId].int ?? 0
    playbackRate = json[CastJSONPayloadKeys.playbackRate].double ?? 1
    playerState = json[CastJSONPayloadKeys.playerState].string.flatMap(CastMediaPlayerState.init) ?? .buffering
    currentTime = json[CastJSONPayloadKeys.currentTime].double ?? 0

    let media = json[CastJSONPayloadKeys.media]
    duration = media[CastJSONPayloadKeys.duration].double
    contentType = media[CastJSONPayloadKeys.contentType].string
    metadata = media[CastJSONPayloadKeys.metadata]

    if let contentID = media[CastJSONPayloadKeys.contentId].string, let data = contentID.data(using: .utf8) {
      self.contentID = (try? JSON(data: data))?[CastJSONPayloadKeys.contentId].string ?? contentID
    } else {
      contentID = nil
    }

    idleReasonRaw = json[CastJSONPayloadKeys.idleReason].string
    idleReason = idleReasonRaw.flatMap(CastIdleReason.init)
    supportedMediaCommands = json[CastJSONPayloadKeys.supportedMediaCommands].int ?? 0
    volumeLevel = json[CastJSONPayloadKeys.volume][CastJSONPayloadKeys.level].double
    volumeMuted = json[CastJSONPayloadKeys.volume][CastJSONPayloadKeys.muted].bool

    super.init()
  }
}

import Foundation

public let CastMediaStreamTypeBuffered = "BUFFERED"
public let CastMediaStreamTypeLive = "LIVE"

public enum CastMediaStreamType: String, Sendable {
    case buffered = "BUFFERED"
    case live = "LIVE"
}

public final class CastMedia: NSObject, @unchecked Sendable {
    public let title: String
    public let artist: String?
    public let url: URL
    public let poster: URL?

    public let autoplay: Bool
    public let currentTime: Double

    public let contentType: String
    public let streamType: CastMediaStreamType

    public init(title: String, artist: String? = nil, url: URL, poster: URL? = nil, contentType: String, streamType: CastMediaStreamType = .buffered, autoplay: Bool = true, currentTime: Double = 0) {
        self.title = title
        self.artist = artist
        self.url = url
        self.poster = poster
        self.contentType = contentType
        self.streamType = streamType
        self.autoplay = autoplay
        self.currentTime = currentTime
    }
}

extension CastMedia {

    /// The media object as the receiver wants it: content, type and metadata.
    var mediaDict: [String: Any] {
        var metadata: [String: Any] = [
            CastJSONPayloadKeys.metadataType: 3,
            CastJSONPayloadKeys.title: title
        ]

        if let artist = artist {
            metadata[CastJSONPayloadKeys.artist] = artist
        }

        if let poster = poster {
            metadata[CastJSONPayloadKeys.images] = [
                [CastJSONPayloadKeys.url: poster.absoluteString]
            ]
        }

        return [
            CastJSONPayloadKeys.contentId: url.absoluteString,
            CastJSONPayloadKeys.contentType: contentType,
            CastJSONPayloadKeys.streamType: streamType.rawValue,
            CastJSONPayloadKeys.metadata: metadata
        ]
    }

    /// The LOAD payload.
    var dict: [String: Any] {
        return [
            CastJSONPayloadKeys.autoplay: autoplay,
            CastJSONPayloadKeys.activeTrackIds: [],
            CastJSONPayloadKeys.repeatMode: "REPEAT_OFF",
            CastJSONPayloadKeys.currentTime: currentTime,
            CastJSONPayloadKeys.media: mediaDict
        ]
    }

}

/// An item for the receiver's own queue. `customData` rides along and comes
/// back in the receiver's status, so the sender can tell its items apart.
public struct CastQueueItem: Sendable {
    public let media: CastMedia
    public let autoplay: Bool
    /// Seconds before this item is due that the receiver starts fetching it.
    public let preloadTime: Double
    public let startTime: Double
    public let customData: [String: String]

    public init(media: CastMedia, autoplay: Bool = true, preloadTime: Double = 20, startTime: Double = 0, customData: [String: String] = [:]) {
        self.media = media
        self.autoplay = autoplay
        self.preloadTime = preloadTime
        self.startTime = startTime
        self.customData = customData
    }

    var dict: [String: Any] {
        [
            CastJSONPayloadKeys.media: media.mediaDict,
            CastJSONPayloadKeys.autoplay: autoplay,
            CastJSONPayloadKeys.preloadTime: preloadTime,
            CastJSONPayloadKeys.startTime: startTime,
            CastJSONPayloadKeys.customData: customData
        ]
    }
}

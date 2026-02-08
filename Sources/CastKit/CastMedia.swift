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

    var dict: [String: Any] {
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
            CastJSONPayloadKeys.autoplay: autoplay,
            CastJSONPayloadKeys.activeTrackIds: [],
            CastJSONPayloadKeys.repeatMode: "REPEAT_OFF",
            CastJSONPayloadKeys.currentTime: currentTime,
            CastJSONPayloadKeys.media: [
                CastJSONPayloadKeys.contentId: url.absoluteString,
                CastJSONPayloadKeys.contentType: contentType,
                CastJSONPayloadKeys.streamType: streamType.rawValue,
                CastJSONPayloadKeys.metadata: metadata
            ] as [String : Any]
        ]
    }

}

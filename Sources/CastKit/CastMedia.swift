import Foundation

public let CastMediaStreamTypeBuffered = "BUFFERED"
public let CastMediaStreamTypeLive = "LIVE"

public enum CastMediaStreamType: String, Sendable {
    case buffered = "BUFFERED"
    case live = "LIVE"
}

/// What the receiver shows about the media: Cast's media metadata types.
public enum CastMediaMetadata: Sendable, Equatable {
    case generic(title: String, subtitle: String? = nil)
    case movie(title: String, subtitle: String? = nil, studio: String? = nil, releaseDate: String? = nil)
    /// An episode: its show, its own title, and where it sits.
    case tvShow(seriesTitle: String, episodeTitle: String? = nil, season: Int? = nil, episode: Int? = nil, originalAirdate: String? = nil)
    case musicTrack(title: String, artist: String? = nil, albumName: String? = nil)

    public var title: String {
        switch self {
        case .generic(let title, _), .movie(let title, _, _, _), .musicTrack(let title, _, _): title
        case .tvShow(let series, let episode, _, _, _): episode ?? series
        }
    }
}

/// A track the receiver can switch on (Cast's media tracks): here, mostly a subtitle file.
public struct CastMediaTrack: Sendable, Equatable {
    public enum Kind: String, Sendable { case text = "TEXT", audio = "AUDIO", video = "VIDEO" }
    public enum Subtype: String, Sendable { case subtitles = "SUBTITLES", captions = "CAPTIONS", descriptions = "DESCRIPTIONS", chapters = "CHAPTERS", metadata = "METADATA" }

    public let id: Int
    public let kind: Kind
    /// Where the receiver fetches it (a WebVTT file for text).
    public let contentID: URL?
    public let contentType: String?
    public let subtype: Subtype?
    public let name: String?
    /// BCP 47 ("en", "es-MX").
    public let language: String?

    public init(id: Int, kind: Kind = .text, contentID: URL?, contentType: String? = "text/vtt", subtype: Subtype? = .subtitles, name: String? = nil, language: String? = nil) {
        self.id = id
        self.kind = kind
        self.contentID = contentID
        self.contentType = contentType
        self.subtype = subtype
        self.name = name
        self.language = language
    }

    var dict: [String: Any] {
        var track: [String: Any] = [CastJSONPayloadKeys.trackId: id, CastJSONPayloadKeys.type: kind.rawValue]
        if let contentID { track[CastJSONPayloadKeys.trackContentId] = contentID.absoluteString }
        if let contentType { track[CastJSONPayloadKeys.trackContentType] = contentType }
        if let subtype { track[CastJSONPayloadKeys.subtype] = subtype.rawValue }
        if let name { track[CastJSONPayloadKeys.name] = name }
        if let language { track[CastJSONPayloadKeys.language] = language }
        return track
    }
}

/// How the receiver draws text tracks (Cast's text track style). Colours are "#RRGGBBAA".
public struct CastTextTrackStyle: Sendable, Equatable {
    public enum EdgeType: String, Sendable { case none = "NONE", outline = "OUTLINE", dropShadow = "DROP_SHADOW", raised = "RAISED", depressed = "DEPRESSED" }
    public enum FontFamily: String, Sendable { case sansSerif = "SANS_SERIF", monospacedSansSerif = "MONOSPACED_SANS_SERIF", serif = "SERIF" }

    public var foregroundColor: String
    public var backgroundColor: String
    public var edgeType: EdgeType
    public var edgeColor: String
    /// 1 is the receiver's own size.
    public var fontScale: Double
    public var fontFamily: FontFamily

    public init(foregroundColor: String = "#FFFFFFFF", backgroundColor: String = "#00000000", edgeType: EdgeType = .dropShadow,
                edgeColor: String = "#000000FF", fontScale: Double = 1, fontFamily: FontFamily = .sansSerif) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.edgeType = edgeType
        self.edgeColor = edgeColor
        self.fontScale = fontScale
        self.fontFamily = fontFamily
    }

    var dict: [String: Any] {
        ["foregroundColor": foregroundColor, "backgroundColor": backgroundColor, "edgeType": edgeType.rawValue,
         "edgeColor": edgeColor, "fontScale": fontScale, "fontGenericFamily": fontFamily.rawValue]
    }
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

    /// What the receiver shows; nil = a music track from `title` and `artist` (CastKit before 1.6).
    public let metadata: CastMediaMetadata?
    /// The length in seconds, when known (the receiver shows it before the stream says).
    public let duration: Double?
    public let tracks: [CastMediaTrack]
    /// The tracks on at load (`tracks`' ids).
    public let activeTrackIds: [Int]
    public let textTrackStyle: CastTextTrackStyle?
    /// An HLS stream's audio and video segment formats ("aac", "ts", "fmp4"; "mpeg2_ts",
    /// "fmp4"), which the receiver otherwise guesses.
    public let hlsSegmentFormat: String?
    public let hlsVideoSegmentFormat: String?
    public let customData: [String: String]

    public init(title: String, artist: String? = nil, url: URL, poster: URL? = nil, contentType: String, streamType: CastMediaStreamType = .buffered, autoplay: Bool = true, currentTime: Double = 0) {
        self.title = title
        self.artist = artist
        self.url = url
        self.poster = poster
        self.contentType = contentType
        self.streamType = streamType
        self.autoplay = autoplay
        self.currentTime = currentTime
        metadata = nil
        duration = nil
        tracks = []
        activeTrackIds = []
        textTrackStyle = nil
        hlsSegmentFormat = nil
        hlsVideoSegmentFormat = nil
        customData = [:]
    }

    /// Video and the rest: any metadata type, tracks (subtitles), the length and HLS hints.
    public init(url: URL, contentType: String, metadata: CastMediaMetadata, poster: URL? = nil, streamType: CastMediaStreamType = .buffered,
                duration: Double? = nil, tracks: [CastMediaTrack] = [], activeTrackIds: [Int] = [], textTrackStyle: CastTextTrackStyle? = nil,
                hlsSegmentFormat: String? = nil, hlsVideoSegmentFormat: String? = nil, autoplay: Bool = true, currentTime: Double = 0,
                customData: [String: String] = [:]) {
        self.url = url
        self.contentType = contentType
        self.metadata = metadata
        title = metadata.title
        if case .musicTrack(_, let artist, _) = metadata { self.artist = artist } else { artist = nil }
        self.poster = poster
        self.streamType = streamType
        self.duration = duration
        self.tracks = tracks
        self.activeTrackIds = activeTrackIds
        self.textTrackStyle = textTrackStyle
        self.hlsSegmentFormat = hlsSegmentFormat
        self.hlsVideoSegmentFormat = hlsVideoSegmentFormat
        self.autoplay = autoplay
        self.currentTime = currentTime
        self.customData = customData
    }
}

extension CastMedia {

    /// The metadata object as the receiver wants it.
    var metadataDict: [String: Any] {
        var dict: [String: Any]
        switch metadata ?? .musicTrack(title: title, artist: artist) {
        case let .generic(title, subtitle):
            dict = [CastJSONPayloadKeys.metadataType: 0, CastJSONPayloadKeys.title: title]
            if let subtitle { dict[CastJSONPayloadKeys.subtitle] = subtitle }
        case let .movie(title, subtitle, studio, releaseDate):
            dict = [CastJSONPayloadKeys.metadataType: 1, CastJSONPayloadKeys.title: title]
            if let subtitle { dict[CastJSONPayloadKeys.subtitle] = subtitle }
            if let studio { dict[CastJSONPayloadKeys.studio] = studio }
            if let releaseDate { dict[CastJSONPayloadKeys.releaseDate] = releaseDate }
        case let .tvShow(seriesTitle, episodeTitle, season, episode, originalAirdate):
            dict = [CastJSONPayloadKeys.metadataType: 2, CastJSONPayloadKeys.seriesTitle: seriesTitle]
            if let episodeTitle { dict[CastJSONPayloadKeys.title] = episodeTitle }
            if let season { dict[CastJSONPayloadKeys.season] = season }
            if let episode { dict[CastJSONPayloadKeys.episode] = episode }
            if let originalAirdate { dict[CastJSONPayloadKeys.originalAirdate] = originalAirdate }
        case let .musicTrack(title, artist, albumName):
            dict = [CastJSONPayloadKeys.metadataType: 3, CastJSONPayloadKeys.title: title]
            if let artist { dict[CastJSONPayloadKeys.artist] = artist }
            if let albumName { dict[CastJSONPayloadKeys.albumName] = albumName }
        }
        if let poster {
            dict[CastJSONPayloadKeys.images] = [[CastJSONPayloadKeys.url: poster.absoluteString]]
        }
        return dict
    }

    /// The media object as the receiver wants it: content, type and metadata, and for video
    /// its tracks, length and HLS hints.
    var mediaDict: [String: Any] {
        var media: [String: Any] = [
            CastJSONPayloadKeys.contentId: url.absoluteString,
            CastJSONPayloadKeys.contentType: contentType,
            CastJSONPayloadKeys.streamType: streamType.rawValue,
            CastJSONPayloadKeys.metadata: metadataDict
        ]
        if let duration { media[CastJSONPayloadKeys.duration] = duration }
        if !tracks.isEmpty { media[CastJSONPayloadKeys.tracks] = tracks.map(\.dict) }
        if let textTrackStyle { media[CastJSONPayloadKeys.textTrackStyle] = textTrackStyle.dict }
        if let hlsSegmentFormat { media[CastJSONPayloadKeys.hlsSegmentFormat] = hlsSegmentFormat }
        if let hlsVideoSegmentFormat { media[CastJSONPayloadKeys.hlsVideoSegmentFormat] = hlsVideoSegmentFormat }
        if !customData.isEmpty { media[CastJSONPayloadKeys.customData] = customData }
        return media
    }

    /// The LOAD payload.
    var dict: [String: Any] {
        return [
            CastJSONPayloadKeys.autoplay: autoplay,
            CastJSONPayloadKeys.activeTrackIds: activeTrackIds,
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

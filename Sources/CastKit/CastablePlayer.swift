import Foundation

@MainActor
public protocol CastablePlayer: AnyObject {
    var trackTitle: String { get }
    var artistName: String { get }
    var albumArtworkURL: URL? { get }
    /// Current playback position in seconds.
    var currentPlaybackTime: TimeInterval { get }
    /// Whether there is anything loaded to cast. Connecting with nothing
    /// loaded used to cast whatever URL was set last.
    var hasMedia: Bool { get }
    /// Whether the player is playing, so the receiver starts in the same
    /// state instead of always playing.
    var isPlaying: Bool { get }
    func muteForCast()
    func unmuteFromCast()
    func pause()
    func updateNowPlayingInfo()
}

public extension CastablePlayer {
    var hasMedia: Bool { !trackTitle.isEmpty }
    var isPlaying: Bool { true }
}

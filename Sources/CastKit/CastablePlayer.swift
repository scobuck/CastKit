import Foundation

@MainActor
public protocol CastablePlayer: AnyObject {
    var trackTitle: String { get }
    var artistName: String { get }
    var albumArtworkURL: URL? { get }
    /// Current playback position in seconds.
    var currentPlaybackTime: TimeInterval { get }
    func muteForCast()
    func unmuteFromCast()
    func pause()
    func updateNowPlayingInfo()
}

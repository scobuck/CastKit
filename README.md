# CastKit

A Swift Package for Google Cast (Chromecast) integration in SwiftUI apps.

CastKit provides device discovery, connection management, media casting, and a ready-to-use SwiftUI cast button — everything needed to add Chromecast support to an iOS or macOS app.

## Requirements

- iOS 17+ / macOS 14+
- Swift 6.0+

## Installation

Add CastKit to your project via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/scobuck/CastKit", from: "1.0.0")
]
```

## Usage

### 1. Set up CastManager

Create a `CastManager` as a `@StateObject` and inject it into the environment:

```swift
@main
struct MyApp: App {
    @StateObject private var castManager = CastManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(castManager)
                .onAppear {
                    castManager.streamURL = "https://example.com/stream"
                    castManager.stationName = "My Station"
                    castManager.player = myPlayer
                    castManager.startScanning()
                }
        }
    }
}
```

### 2. Conform to CastablePlayer

Your player class needs to conform to `CastablePlayer` so CastKit can coordinate playback:

```swift
extension MyPlayer: CastablePlayer {
    var trackTitle: String { ... }
    var artistName: String { ... }
    var albumArtworkURL: URL? { ... }
    func muteForCast() { ... }
    func unmuteFromCast() { ... }
    func pause() { ... }
    func updateNowPlayingInfo() { ... }
}
```

### 3. Add the Cast Button

Drop `CastButton()` into your toolbar or view hierarchy. It handles device discovery, selection, and connection state automatically:

```swift
.toolbar {
    ToolbarItem(placement: .automatic) {
        CastButton()
    }
}
```

### 4. Control Playback

```swift
@EnvironmentObject var castManager: CastManager

// Cast the stream
castManager.castStream()

// Toggle play/pause
castManager.toggleCastPlayback()

// Adjust volume
castManager.setCastVolume(0.5)

// Disconnect
castManager.disconnect()
```

### 5. Video (1.6)

```swift
// An episode, with a WebVTT subtitle track on at load.
let media = CastMedia(
    url: streamURL, contentType: "application/x-mpegurl",
    metadata: .tvShow(seriesTitle: "Neagley", episodeTitle: "Team Building Exercises", season: 1, episode: 2),
    poster: stillURL, duration: 2820,
    tracks: [CastMediaTrack(id: 1, contentID: vttURL, name: "English", language: "en")],
    activeTrackIds: [1], textTrackStyle: CastTextTrackStyle(fontScale: 1.2),
    hlsSegmentFormat: "aac", hlsVideoSegmentFormat: "mpeg2_ts", currentTime: 600)
castManager.load(media)

castManager.setActiveTracks([])      // subtitles off
castManager.setActiveTracks([1])     // back on
castManager.setPlaybackRate(1.5)
castManager.receiverAppId = "ABCD1234" // your Styled or Custom receiver, before connecting
```

Metadata types: `.generic`, `.movie`, `.tvShow`, `.musicTrack` (the original `CastMedia(title:artist:…)` initializer still sends a music track).

**Google's Default Media Receiver fetches media from a web origin (`https://www.gstatic.com`), so the server must send CORS headers** (`Access-Control-Allow-Origin`) on playlists, segments and subtitle files; without them it fetches the playlist and goes IDLE/ERROR (Nest Hub, 2026-11-13). Real-device check: `CASTKIT_REAL_DEVICE=<name> CASTKIT_REAL_VIDEO=<HLS URL> [CASTKIT_REAL_VTT=<WebVTT URL>] swift test --filter testPlaysVideoOnARealReceiver`.

## What's Included

- **CastManager** — High-level `ObservableObject` managing the full Cast lifecycle
- **CastablePlayer** — Protocol to decouple your player from CastKit
- **CastButton / CastIcon** — SwiftUI views for the standard Cast icon and device picker
- **CastDeviceScanner** — Bonjour-based device discovery
- **CastClient** — Low-level Google Cast V2 protocol client (TLS, protobuf, channels)
- **Channel types** — Heartbeat, receiver control, media control, multizone, device auth/connection/discovery/setup

## Acknowledgements

CastKit is inspired by [OpenCastSwift](https://github.com/mhmiles/OpenCastSwift) by Miles Ake, an early open-source Swift implementation of the Google Cast protocol.

## Dependencies

- [apple/swift-protobuf](https://github.com/apple/swift-protobuf) (1.28.0+, Apache 2.0) — for the Cast V2 protocol
- [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON) (MIT, vendored) — JSON parsing

## License

MIT — see [LICENSE](LICENSE) for details.

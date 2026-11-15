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

### 6. Your own receiver (1.7)

A Custom Web Receiver can tell the sender what the device and its screen can show (Google's `canDisplayType` and `getDeviceCapabilities` only run in receiver code), on your own namespace:

```swift
castManager.receiverAppId = "ABCD1234"                       // your registered receiver
castManager.registerNamespace("urn:x-cast:com.example.app")  // before or after connecting
castManager.launchApp { result in                             // launches (or joins) it, loads nothing
    castManager.sendMessage(["type": "CAPABILITIES"], namespace: "urn:x-cast:com.example.app") { reply in
        // .success(jsonText): the receiver's answer carrying the same requestId
    }
}
castManager.onCustomMessage = { namespace, jsonText in }     // messages it sends unasked
castManager.videoInfo                                         // what it reports showing: width, height, hdrType
```

The receiver answers with `context.sendCustomMessage(namespace, senderId, { ...reply, requestId })`, keeping the request's `requestId`.

### 7. Device authentication (1.8)

Every connection proves the receiver is a genuine Google Cast device before anything is sent to it, the way Chrome and Google's Cast SDK do. Right after the TLS handshake CastKit sends Cast's device-auth challenge with a fresh 16-byte nonce. The receiver answers with its device certificate, its intermediates and a signature over the nonce and its own TLS certificate, and CastKit checks that:

- the certificates chain to Google's Cast Root CA or Eureka Root CA (from Chromium's source, embedded in `CastTrustRoots`), under Chromium's rules for key sizes, algorithms, key usage and expiry;
- the device key signed this connection's nonce and TLS certificate (RSASSA-PKCS1-v1_5 with SHA-256, or SHA-1 from older devices), so a signature can't be replayed or relayed;
- the TLS certificate is current and runs no more than four days ahead;
- nothing on the chain is revoked, by the device's own CRL or by Chromium's fallback CRL.

A receiver that fails is sent nothing but the challenge, and the connection fails with `CastError.deviceAuthenticationFailed(reason:)` (through `onCastError` on `CastManager`, or `castClient(_:connectionTo:didFailWith:)`). It can't be switched off. If you `switch` over `CastError` exhaustively, add the new case.

Where CastKit differs from Chromium: the nonce must come back unchanged (Chromium only notes a mismatch); the fallback CRL's revocations apply with no expiry date; and RSASSA-PSS-signed certificate chains, which Apple's Security framework can't verify, are refused (Cast's PKI doesn't use them).

Real-device check, which sends the device nothing but the challenge: `CASTKIT_AUTH_ONLY=1 CASTKIT_REAL_DEVICE="<exact name>" swift test --filter testDeviceAuthenticationOnly`.

### 8. In the background (1.9)

On iPhone, iPad and Apple TV the session is suspended when the app goes to the background and resumed when it comes back, as Google's sender SDK does by default. iOS suspends a backgrounded app within seconds, and its connection with it; a dropped connection used to end the session.

- Suspended (`UIApplication.didEnterBackgroundNotification`, or `suspend()`), CastKit leaves the receiver app and closes the connection without stopping anything: the receiver plays on. `isConnected` is false, `suspendedSession` says what to rejoin, and `onCastSuspended` is called. `onCastEnded` is not.
- Resumed (`willEnterForegroundNotification`, or `resume()`), it connects to the same device again (device authentication included), finds the receiver app with the same session id and rejoins it, takes in its media status and calls `onCastResumed` with it. `onCastConnected` isn't called, as nothing new is cast.
- If that session has gone (stopped from the TV, idled out, another sender took over), the session ends as usual: `onCastError`, then `onCastEnded`.

`suspendsSessionWhenBackgrounded = false` turns it off, for an app that keeps its connection alive in the background. Lock Screen and notification controls aren't part of it: Google's sender checklist marks them Android-only.

## What's Included

- **CastManager** — High-level `ObservableObject` managing the full Cast lifecycle
- **CastablePlayer** — Protocol to decouple your player from CastKit
- **CastButton / CastIcon** — SwiftUI views for the standard Cast icon and device picker
- **CastDeviceScanner** — Bonjour-based device discovery
- **CastClient** — Low-level Google Cast V2 protocol client (TLS, device authentication, protobuf, channels)
- **Channel types** — Heartbeat, receiver control, media control, multizone, device auth/connection/discovery/setup

## Acknowledgements

CastKit is inspired by [OpenCastSwift](https://github.com/mhmiles/OpenCastSwift) by Miles Ake, an early open-source Swift implementation of the Google Cast protocol.

## Dependencies

- [apple/swift-protobuf](https://github.com/apple/swift-protobuf) (1.28.0+, Apache 2.0) — for the Cast V2 protocol
- [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON) (MIT, vendored) — JSON parsing

## License

MIT — see [LICENSE](LICENSE) for details.

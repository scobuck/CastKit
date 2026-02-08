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

## What's Included

- **CastManager** — High-level `ObservableObject` managing the full Cast lifecycle
- **CastablePlayer** — Protocol to decouple your player from CastKit
- **CastButton / CastIcon** — SwiftUI views for the standard Cast icon and device picker
- **CastDeviceScanner** — Bonjour-based device discovery
- **CastClient** — Low-level Google Cast V2 protocol client (TLS, protobuf, channels)
- **Channel types** — Heartbeat, receiver control, media control, multizone, device auth/connection/discovery/setup

## Dependencies

- [apple/swift-protobuf](https://github.com/apple/swift-protobuf) (1.28.0+) — for the Cast V2 protocol

## License

MIT

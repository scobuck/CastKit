import Foundation
import SwiftUI

@MainActor
public class CastManager: ObservableObject {
    @Published public var availableDevices: [CastDevice] = []
    @Published public var isConnected = false
    @Published public var connectedDeviceName: String?
    @Published public var isCastPlaying = false
    @Published public var castVolume: Float = 1.0
    /// Last known playback position on the Cast device (seconds).
    @Published public var castPosition: TimeInterval = 0
    /// Whether the current track's codec is natively supported by Cast devices.
    @Published public var isCurrentTrackCastCompatible = true

    private let scanner = CastDeviceScanner()
    private var client: CastClient?
    private var currentApp: CastApp?
    private var scannerDelegate: ScannerDelegate?
    private var clientDelegate: ClientDelegate?

    /// The stream URL to cast — set by the app before calling castStream().
    public var streamURL: String = ""
    /// The station name to show on the Cast device.
    public var stationName: String = ""
    /// The MIME content type for the stream (e.g. "audio/flac", "audio/mpeg").
    public var contentType: String = "audio/mpeg"
    /// The position (seconds) to start playback from when loading media.
    public var startPosition: TimeInterval = 0
    /// Reference to the local player for pausing/resuming during Cast.
    public weak var player: (any CastablePlayer)?
    /// Called when casting ends with the last known cast playback position.
    public var onCastEnded: ((TimeInterval) -> Void)?
    /// Called when the cast device reports an updated playback position.
    public var onCastPositionUpdated: ((TimeInterval) -> Void)?
    /// Incremented each time a new media load is initiated; used to discard
    /// stale IDLE status updates from a previous track's media session.
    nonisolated(unsafe) var loadGeneration: Int = 0

    public init() {
        scannerDelegate = ScannerDelegate(manager: self)
        scanner.delegate = scannerDelegate

        NotificationCenter.default.addObserver(
            forName: CastDeviceScanner.deviceListDidChange,
            object: scanner,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.availableDevices = self.scanner.devices
            }
        }

        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.client?.stopCurrentApp()
                self.client?.disconnect()
            }
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.client?.stopCurrentApp()
                self.client?.disconnect()
            }
        }
        #endif
    }

    public func startScanning() {
        scanner.startScanning()
    }

    public func restartScanning() {
        scanner.restartScanning()
    }

    public func stopScanning() {
        scanner.stopScanning()
    }

    public func connect(to device: CastDevice) {
        disconnect()

        let newClient = CastClient(device: device)
        let delegate = ClientDelegate(manager: self)
        self.clientDelegate = delegate
        newClient.delegate = delegate
        self.client = newClient
        newClient.connect()
    }

    public func toggleCastPlayback() {
        guard let client = client else { return }
        if isCastPlaying {
            client.pause()
            isCastPlaying = false
            player?.pause()
        } else {
            client.play()
            isCastPlaying = true
            player?.muteForCast()
        }
        player?.updateNowPlayingInfo()
    }

    public func setCastVolume(_ volume: Float) {
        castVolume = volume
        client?.setVolume(volume)
    }

    public func castStream() {
        guard let client = client, client.isConnected else {
            print("[CastManager] castStream: no client or not connected")
            return
        }
        guard let url = URL(string: streamURL) else {
            print("[CastManager] castStream: invalid stream URL: \(streamURL.prefix(80))")
            return
        }

        let trackTitle = player?.trackTitle
        let artistName = player?.artistName
        let artworkURL = player?.albumArtworkURL

        let displayTitle = trackTitle ?? stationName
        let displayArtist = (artistName?.isEmpty == false) ? artistName : nil

        let media = CastMedia(
            title: displayTitle,
            artist: displayArtist,
            url: url,
            poster: artworkURL,
            contentType: contentType,
            streamType: .buffered,
            autoplay: true,
            currentTime: startPosition
        )

        isCastPlaying = true
        loadGeneration += 1

        if let currentApp {
            // Already have a running session — load new media directly
            client.load(media: media, with: currentApp) { [weak self] result in
                Task { @MainActor [weak self] in
                    if case .failure(let error) = result {
                        print("[CastManager] Load failed: \(error)")
                        self?.isCastPlaying = false
                    }
                }
            }
        } else {
            client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { [weak self, weak client] result in
                switch result {
                case .success(let app):
                    // Completion runs on main queue — safe to update and load sequentially
                    Task { @MainActor [weak self, weak client] in
                        guard let self, let client else { return }
                        self.currentApp = app
                        client.load(media: media, with: app) { [weak self] result in
                            Task { @MainActor [weak self] in
                                if case .failure(let error) = result {
                                    print("[CastManager] Load after launch failed: \(error)")
                                    self?.isCastPlaying = false
                                }
                            }
                        }
                    }
                case .failure:
                    Task { @MainActor [weak self] in
                        self?.isCastPlaying = false
                    }
                }
            }
        }
    }

    // MARK: - Direct Playback Control

    /// Pause playback on the Cast device only (does not affect local player).
    public func pauseCast() {
        client?.pause()
        isCastPlaying = false
    }

    /// Resume playback on the Cast device only (does not affect local player).
    public func resumeCast() {
        client?.play()
        isCastPlaying = true
    }

    /// Seek to a position on the Cast device.
    public func seekCast(to seconds: TimeInterval) {
        client?.seek(to: Float(seconds))
    }

    /// Request the current media status from the Cast device.
    /// Triggers `onCastPositionUpdated` callback when the response arrives.
    public func requestMediaStatus() {
        guard let client, let app = currentApp else { return }
        client.requestMediaStatus(for: app) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let status) = result {
                    self.castPosition = status.adjustedCurrentTime
                    self.onCastPositionUpdated?(status.adjustedCurrentTime)
                }
            }
        }
    }

    public func disconnect() {
        let lastPosition = castPosition
        client?.stopCurrentApp()
        client?.disconnect()
        client = nil
        currentApp = nil
        clientDelegate = nil
        isConnected = false
        connectedDeviceName = nil
        isCastPlaying = false
        player?.unmuteFromCast()
        onCastEnded?(lastPosition)
    }

    deinit {
        client?.delegate = nil
        client?.stopCurrentApp()
        client?.disconnect()
    }

    // MARK: - Scanner Delegate

    private class ScannerDelegate: CastDeviceScannerDelegate, @unchecked Sendable {
        weak var manager: CastManager?

        init(manager: CastManager) {
            self.manager = manager
        }

        func deviceDidComeOnline(_ device: CastDevice) {
            MainActor.assumeIsolated {
                guard let manager else { return }
                manager.availableDevices = manager.scanner.devices
            }
        }

        func deviceDidChange(_ device: CastDevice) {
            MainActor.assumeIsolated {
                guard let manager else { return }
                manager.availableDevices = manager.scanner.devices
            }
        }

        func deviceDidGoOffline(_ device: CastDevice) {
            MainActor.assumeIsolated {
                guard let manager else { return }
                manager.availableDevices = manager.scanner.devices
            }
        }
    }

    // MARK: - Client Delegate

    private class ClientDelegate: CastClientDelegate, @unchecked Sendable {
        weak var manager: CastManager?

        init(manager: CastManager) {
            self.manager = manager
        }

        func castClient(_ client: CastClient, didConnectTo device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }
                // Start cast from the player's current position
                manager.startPosition = manager.player?.currentPlaybackTime ?? 0
                manager.player?.muteForCast()
                manager.isConnected = true
                manager.connectedDeviceName = device.name
                manager.isCastPlaying = true
                manager.castStream()
            }
        }

        func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.isConnected else { return }
                let lastPosition = manager.castPosition
                manager.isConnected = false
                manager.connectedDeviceName = nil
                manager.isCastPlaying = false
                manager.player?.unmuteFromCast()
                manager.onCastEnded?(lastPosition)
            }
        }

        func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }
                manager.isConnected = false
                manager.connectedDeviceName = nil
                manager.isCastPlaying = false
                manager.player?.unmuteFromCast()
            }
        }

        func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }
                manager.castVolume = Float(status.volume)
            }
        }

        func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {
            // Snapshot generation before hopping to MainActor — if a new LOAD
            // is issued before the Task runs, the IDLE status is stale.
            let gen = manager?.loadGeneration ?? -1
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }

                // When the cast device goes IDLE (track finished or error), don't
                // propagate the stale position — it belongs to the old track and
                // would seek the local player to the wrong place in the new track.
                if status.playerState == .idle {
                    if let reason = status.idleReason {
                        print("[CastManager] Cast went idle: \(reason) (gen=\(gen)/\(manager.loadGeneration))")
                    }
                    // Only mark as not playing if no new load was issued since the IDLE arrived
                    if manager.loadGeneration == gen {
                        manager.isCastPlaying = false
                    }
                    return
                }

                manager.castPosition = status.adjustedCurrentTime
                manager.onCastPositionUpdated?(status.adjustedCurrentTime)
            }
        }
    }
}

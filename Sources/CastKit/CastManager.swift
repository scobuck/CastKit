import Foundation
import SwiftUI

@MainActor
public class CastManager: ObservableObject {
    @Published public var availableDevices: [CastDevice] = []
    @Published public var isConnected = false
    /// A connection attempt is in progress.
    @Published public var isConnecting = false
    @Published public var connectedDeviceName: String?
    @Published public var connectedDeviceId: String?
    /// Whether the receiver is playing (or buffering towards playing), as
    /// the receiver itself reports it — including changes made elsewhere,
    /// from the Home app or by voice.
    @Published public var isCastPlaying = false
    /// The receiver's player state, as last reported.
    @Published public var playerState: CastMediaPlayerState = .idle
    @Published public var castVolume: Float = 1.0
    /// Last known playback position on the Cast device (seconds).
    @Published public var castPosition: TimeInterval = 0
    /// Whether the current track's codec is natively supported by Cast devices.
    @Published public var isCurrentTrackCastCompatible = true
    /// Why discovery can't find devices, when it can't: local network
    /// access denied, no network. Nil while scanning works.
    @Published public var scanError: String?

    private let scanner = CastDeviceScanner()
    private var client: CastClient?
    private var currentApp: CastApp?
    private var scannerDelegate: ScannerDelegate?
    private var clientDelegate: ClientDelegate?
    private var lastMediaStatus: CastMediaStatus?
    /// Set while a LOAD is outstanding: idle reports arriving then belong
    /// to the media being replaced, not to the new one.
    private var loadInFlight = false
    /// Whether this manager has muted the app's player for the session.
    private var playerMuted = false

    /// The stream URL to cast — set by the app before calling castStream().
    public var streamURL: String = ""
    /// The station name to show on the Cast device.
    public var stationName: String = ""
    /// The MIME content type for the stream (e.g. "audio/flac", "audio/mpeg").
    public var contentType: String = "audio/mpeg"
    /// Buffered for tracks; live for radio streams.
    public var streamType: CastMediaStreamType = .buffered
    /// The position (seconds) to start playback from when loading media.
    public var startPosition: TimeInterval = 0
    /// Reference to the local player for pausing/resuming during Cast.
    public weak var player: (any CastablePlayer)?
    /// Called when casting ends with the receiver's last known playback
    /// position — before the local player is unmuted, so the app can move
    /// it while it is still silent.
    public var onCastEnded: ((TimeInterval) -> Void)?
    /// Called when the cast device reports an updated playback position.
    public var onCastPositionUpdated: ((TimeInterval) -> Void)?
    /// The receiver's player changed state — playing, paused, buffering,
    /// idle — including changes made elsewhere.
    public var onCastStateChanged: ((CastMediaPlayerState) -> Void)?
    /// The receiver's media went idle: it finished, was stopped, or failed.
    /// Not called for media replaced by a new load.
    public var onCastIdle: ((CastIdleReason?) -> Void)?
    /// Something failed — a load the receiver rejected, a lost connection,
    /// the receiver app going away — and the session has been ended.
    public var onCastError: ((CastError) -> Void)?
    /// Incremented each time a new media load is initiated, so a reply to
    /// an earlier load is ignored.
    private var loadGeneration: Int = 0

    /// The receiver's position now, extrapolated only while it is playing.
    public var estimatedPosition: TimeInterval {
        lastMediaStatus?.estimatedCurrentTime ?? castPosition
    }

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
        scanError = nil
        scanner.startScanning()
    }

    public func restartScanning() {
        scanError = nil
        scanner.restartScanning()
    }

    public func stopScanning() {
        scanner.stopScanning()
    }

    public func connect(to device: CastDevice) {
        if client != nil || isConnected || isConnecting {
            disconnect()
        }
        isConnecting = true

        let newClient = CastClient(device: device)
        let delegate = ClientDelegate(manager: self)
        self.clientDelegate = delegate
        newClient.delegate = delegate
        self.client = newClient
        newClient.connect()
    }

    public func toggleCastPlayback() {
        if isCastPlaying {
            pauseCast()
        } else {
            resumeCast()
        }
    }

    public func setCastVolume(_ volume: Float) {
        castVolume = volume
        client?.setVolume(volume)
    }

    /// Loads `streamURL` on the receiver. With nothing to cast — no URL,
    /// or a player with nothing loaded — it does nothing; it used to load
    /// whatever URL was set last. The receiver starts playing or paused to
    /// match the player, unless `autoplay` says otherwise.
    public func castStream(autoplay: Bool? = nil) {
        guard let client = client, client.isConnected else {
            print("[CastManager] castStream: no client or not connected")
            return
        }
        guard !streamURL.isEmpty, let url = URL(string: streamURL) else {
            print("[CastManager] castStream: no stream to cast")
            return
        }
        if let player, !player.hasMedia {
            print("[CastManager] castStream: player has nothing loaded")
            return
        }

        muteLocalPlayer()

        let trackTitle = player?.trackTitle
        let artistName = player?.artistName
        let artworkURL = player?.albumArtworkURL

        let displayTitle = (trackTitle?.isEmpty == false) ? trackTitle! : stationName
        let displayArtist = (artistName?.isEmpty == false) ? artistName : nil
        let shouldPlay = autoplay ?? (player?.isPlaying ?? true)

        let media = CastMedia(
            title: displayTitle,
            artist: displayArtist,
            url: url,
            poster: artworkURL,
            contentType: contentType,
            streamType: streamType,
            autoplay: shouldPlay,
            currentTime: startPosition
        )

        isCastPlaying = shouldPlay
        playerState = .buffering
        loadGeneration += 1
        let generation = loadGeneration
        loadInFlight = true

        let load: @MainActor (CastApp) -> Void = { [weak self, weak client] app in
            client?.load(media: media, with: app) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.loadInFlight = false
                    switch result {
                    case .success(let status):
                        self.apply(status)
                    case .failure(let error):
                        print("[CastManager] Load failed: \(error)")
                        self.fail(with: error)
                    }
                }
            }
        }

        if let currentApp {
            // Already have a running session — load new media directly
            load(currentApp)
        } else {
            client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    switch result {
                    case .success(let app):
                        self.currentApp = app
                        load(app)
                    case .failure(let error):
                        print("[CastManager] Launch failed: \(error)")
                        self.loadInFlight = false
                        self.fail(with: error)
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
                    self.apply(status)
                }
            }
        }
    }

    public func disconnect() {
        endSession(stopApp: true)
    }

    deinit {
        client?.delegate = nil
        client?.stopCurrentApp()
        client?.disconnect()
    }

    // MARK: - Session state

    /// Takes in a report from the receiver.
    private func apply(_ status: CastMediaStatus) {
        if status.playerState == .idle {
            // Idle reports that arrive while a new load is outstanding
            // belong to the media being replaced.
            guard !loadInFlight else { return }
            lastMediaStatus = status
            isCastPlaying = false
            let wasIdle = playerState == .idle
            playerState = .idle
            if !wasIdle {
                onCastStateChanged?(.idle)
                onCastIdle?(status.idleReason)
            }
            return
        }

        lastMediaStatus = status
        castPosition = status.estimatedCurrentTime
        isCastPlaying = status.playerState == .playing || status.playerState == .buffering
        if playerState != status.playerState {
            playerState = status.playerState
            onCastStateChanged?(status.playerState)
        }
        onCastPositionUpdated?(castPosition)
    }

    /// The receiver reported that its media session is over.
    private func mediaSessionEnded() {
        guard !loadInFlight else { return }
        isCastPlaying = false
        let wasIdle = playerState == .idle
        playerState = .idle
        if !wasIdle {
            onCastStateChanged?(.idle)
            onCastIdle?(nil)
        }
    }

    /// Ends the session over a failure and tells the app.
    private func fail(with error: CastError) {
        endSession(stopApp: false)
        onCastError?(error)
    }

    /// Ends the session: tells the app where the receiver was, then gives
    /// it its player back. The order matters — the app moves the player
    /// while it is still silent. With no session to end, nothing is said.
    private func endSession(stopApp: Bool) {
        let hadSession = client != nil || isConnected || isConnecting
        let lastPosition = estimatedPosition

        if stopApp { client?.stopCurrentApp() }
        client?.delegate = nil
        client?.disconnect()
        client = nil
        currentApp = nil
        clientDelegate = nil
        isConnected = false
        isConnecting = false
        connectedDeviceName = nil
        connectedDeviceId = nil
        isCastPlaying = false
        playerState = .idle
        lastMediaStatus = nil
        castPosition = 0
        loadInFlight = false
        loadGeneration += 1

        guard hadSession else { return }
        onCastEnded?(lastPosition)
        unmuteLocalPlayer()
    }

    private func muteLocalPlayer() {
        guard !playerMuted else { return }
        playerMuted = true
        player?.muteForCast()
    }

    private func unmuteLocalPlayer() {
        guard playerMuted else { return }
        playerMuted = false
        player?.unmuteFromCast()
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
                manager.scanError = nil
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

        func scannerDidFail(_ message: String) {
            MainActor.assumeIsolated {
                guard let manager else { return }
                manager.scanError = message
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
                guard let manager = self?.manager, manager.client === client else { return }
                manager.isConnecting = false
                manager.isConnected = true
                manager.connectedDeviceName = device.name
                manager.connectedDeviceId = device.id
                // Cast what is playing, from where it is. With nothing
                // loaded, the connection just waits for the next track.
                if let player = manager.player, player.hasMedia, !manager.streamURL.isEmpty {
                    manager.startPosition = player.currentPlaybackTime
                    manager.castStream(autoplay: player.isPlaying)
                }
            }
        }

        func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.endSession(stopApp: false)
                manager.onCastError?(.disconnected)
            }
        }

        func castClient(_ client: CastClient, connectionTo device: CastDevice, didFailWith error: Error?) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.endSession(stopApp: false)
                let castError = (error as? CastError) ?? .connection(error?.localizedDescription ?? "Could not connect")
                manager.onCastError?(castError)
            }
        }

        func castClient(_ client: CastClient, deviceStatusDidChange status: CastStatus) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.castVolume = Float(status.volume)
            }
        }

        func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.apply(status)
            }
        }

        func castClient(_ client: CastClient, mediaSessionDidEnd mediaSessionId: Int) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.mediaSessionEnded()
            }
        }

        func castClient(_ client: CastClient, appSessionDidEnd app: CastApp) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                // The receiver app is gone — quit, idled out, or taken
                // over by another sender. The speaker has stopped, so the
                // app gets its player back.
                manager.fail(with: .session("The receiver stopped playing"))
            }
        }

        func castClient(_ client: CastClient, mediaDidFail error: CastError) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.fail(with: error)
            }
        }
    }
}

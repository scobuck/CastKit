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
    /// The device connection is up. Nothing has been cast yet.
    public var onCastConnected: (() -> Void)?
    /// Why the last session ended, when it wasn't the app that ended it.
    /// Set before `onCastEnded` fires, so its handler can tell.
    public private(set) var endReason: CastError?
    /// Whether the receiver was playing when the last session ended.
    public private(set) var wasPlayingAtEnd = false
    /// The media length the receiver last reported, when it has reported one.
    public var mediaDuration: TimeInterval? { lastKnownDuration }
    private var lastKnownDuration: TimeInterval?
    /// The queue item the receiver is playing, when it plays from a queue.
    @Published public private(set) var currentItemId: Int?
    /// The custom data of the item the receiver is playing, as the sender
    /// attached it — how the app tells which of its tracks is playing.
    @Published public private(set) var currentItemCustomData: [String: String] = [:]
    /// The receiver moved to another item of its queue.
    public var onCastItemChanged: ((_ itemId: Int, _ customData: [String: String]) -> Void)?
    /// The receiver's queue changed; these are the ids it holds now.
    public var onCastQueueChanged: (([Int]) -> Void)?
    /// Whether the receiver app is stopped when this app is terminated.
    /// Off, the receiver plays on through whatever it has queued.
    public var stopsReceiverOnTerminate = true
    /// Items the receiver reported, by id — their custom data.
    private var knownItems: [Int: [String: String]] = [:]
    /// The custom data of every queue item the receiver has reported, by id.
    public var knownItemCustomData: [Int: [String: String]] { knownItems }
    /// The receiver's queue, in order, as last reported.
    @Published public private(set) var queueItemIds: [Int] = []
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
                if self.stopsReceiverOnTerminate { self.client?.stopCurrentApp() }
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
                if self.stopsReceiverOnTerminate { self.client?.stopCurrentApp() }
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
        endReason = nil
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
        load(media)
    }

    /// Loads media on the receiver, launching the receiver app first when
    /// it isn't running. Unlike `castStream`, the media comes in whole and
    /// the app's own player is left alone.
    public func load(_ media: CastMedia) {
        guard let client = client, client.isConnected else {
            print("[CastManager] load: no client or not connected")
            return
        }
        isCastPlaying = media.autoplay
        playerState = .buffering
        lastKnownDuration = nil
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
                        // The Default Media Receiver answers LOAD with an idle
                        // status before it has started buffering; the real
                        // state follows as a broadcast. An idle reply with a
                        // reason is a failure, and is treated as one.
                        if status.playerState == .idle, status.idleReason == nil { return }
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

    /// Loads a queue on the receiver, launching the receiver app first when
    /// it isn't running. The receiver preloads each next item and runs on
    /// through the queue by itself.
    public func loadQueue(_ items: [CastQueueItem], startIndex: Int = 0, startTime: TimeInterval = 0) {
        guard let client = client, client.isConnected else {
            print("[CastManager] loadQueue: no client or not connected")
            return
        }
        isCastPlaying = items.indices.contains(startIndex) ? items[startIndex].autoplay : true
        playerState = .buffering
        lastKnownDuration = nil
        knownItems = [:]
        queueItemIds = []
        currentItemId = nil
        currentItemCustomData = [:]
        loadGeneration += 1
        let generation = loadGeneration
        loadInFlight = true

        let load: @MainActor (CastApp) -> Void = { [weak self, weak client] app in
            client?.queueLoad(items: items, startIndex: startIndex, startTime: startTime, with: app) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.loadInFlight = false
                    switch result {
                    case .success(let status):
                        if status.playerState == .idle, status.idleReason == nil { return }
                        self.apply(status)
                    case .failure(let error):
                        print("[CastManager] Queue load failed: \(error)")
                        self.fail(with: error)
                    }
                }
            }
        }

        if let currentApp {
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

    /// Adds items after the receiver's current item (or before `before`).
    public func insertQueueItems(_ items: [CastQueueItem], before itemId: Int? = nil) {
        client?.queueInsert(items: items, insertBefore: itemId) { [weak self] result in
            Task { @MainActor [weak self] in
                if case .success(let status) = result { self?.apply(status) }
            }
        }
    }

    public func removeQueueItems(_ itemIds: [Int]) {
        guard !itemIds.isEmpty else { return }
        client?.queueRemove(itemIds: itemIds) { [weak self] result in
            Task { @MainActor [weak self] in
                if case .success(let status) = result { self?.apply(status) }
            }
        }
    }

    public func queueNext() { client?.queueJump(1) }
    public func queuePrevious() { client?.queueJump(-1) }

    /// Stops the media on the receiver; the receiver app stays running.
    public func stopMedia() {
        client?.stop()
        isCastPlaying = false
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
        endReason = nil
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
                print("[CastManager] receiver idle: \(status.idleReasonRaw ?? "-")")
                onCastStateChanged?(.idle)
                onCastIdle?(status.idleReason)
            }
            return
        }

        lastMediaStatus = status
        if let duration = status.duration, duration > 0 { lastKnownDuration = duration }
        noteQueue(in: status)
        castPosition = status.estimatedCurrentTime
        isCastPlaying = status.playerState == .playing || status.playerState == .buffering
        if playerState != status.playerState {
            print("[CastManager] receiver \(status.playerState.rawValue) at \(String(format: "%.1f", status.currentTime))s")
            playerState = status.playerState
            onCastStateChanged?(status.playerState)
        }
        onCastPositionUpdated?(castPosition)
    }

    /// Remembers the items a status carries and notices the receiver moving
    /// to another one. A status doesn't always list the items, so those
    /// seen earlier are kept by id.
    private func noteQueue(in status: CastMediaStatus) {
        if let items = status.items {
            for item in items { knownItems[item.itemId] = item.customData }
            queueItemIds = items.map(\.itemId)
        }
        guard let itemId = status.currentItemId, itemId != 0 else { return }
        if itemId != currentItemId {
            currentItemId = itemId
            currentItemCustomData = knownItems[itemId] ?? [:]
            onCastItemChanged?(itemId, currentItemCustomData)
        }
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
        endReason = error
        endSession(stopApp: false)
        onCastError?(error)
    }

    /// Ends the session: tells the app where the receiver was, then gives
    /// it its player back. The order matters — the app moves the player
    /// while it is still silent. With no session to end, nothing is said.
    private func endSession(stopApp: Bool) {
        let hadSession = client != nil || isConnected || isConnecting
        let lastPosition = estimatedPosition
        wasPlayingAtEnd = isCastPlaying

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
        knownItems = [:]
        queueItemIds = []
        currentItemId = nil
        currentItemCustomData = [:]

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
                manager.onCastConnected?()
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

        func castClient(_ client: CastClient, queueChanged itemIds: [Int], changeType: String) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager, manager.client === client else { return }
                manager.queueItemIds = itemIds
                manager.onCastQueueChanged?(itemIds)
            }
        }
    }
}

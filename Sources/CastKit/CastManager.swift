import Foundation
import SwiftUI

@MainActor
public class CastManager: ObservableObject {
    @Published public var availableDevices: [CastDevice] = []
    @Published public var isConnected = false
    @Published public var connectedDeviceName: String?
    @Published public var isCastPlaying = false
    @Published public var castVolume: Float = 1.0

    private let scanner = CastDeviceScanner()
    private var client: CastClient?
    private var scannerDelegate: ScannerDelegate?
    private var clientDelegate: ClientDelegate?

    /// The stream URL to cast — set by the app on launch.
    public var streamURL: String = ""
    /// The station name to show on the Cast device.
    public var stationName: String = ""
    /// Reference to the local player for pausing/resuming during Cast.
    public weak var player: (any CastablePlayer)?

    public init() {
        scannerDelegate = ScannerDelegate(manager: self)
        scanner.delegate = scannerDelegate

        NotificationCenter.default.addObserver(
            forName: CastDeviceScanner.deviceListDidChange,
            object: scanner,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.availableDevices = self.scanner.devices
        }

        #if os(iOS) || os(tvOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.client?.stopCurrentApp()
            self.client?.disconnect()
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.client?.stopCurrentApp()
            self.client?.disconnect()
        }
        #endif
    }

    public func startScanning() {
        scanner.startScanning()
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
        guard let client = client, client.isConnected else { return }
        guard let url = URL(string: streamURL) else { return }

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
            contentType: "audio/mpeg",
            streamType: .live,
            autoplay: true
        )

        isCastPlaying = true
        client.launch(appId: CastAppIdentifier.defaultMediaPlayer) { [weak client] result in
            switch result {
            case .success(let app):
                client?.load(media: media, with: app) { _ in }
            case .failure:
                break
            }
        }
    }

    public func disconnect() {
        client?.stopCurrentApp()
        client?.disconnect()
        client = nil
        clientDelegate = nil
        isConnected = false
        connectedDeviceName = nil
        isCastPlaying = false
        player?.unmuteFromCast()
    }

    // MARK: - Scanner Delegate

    private class ScannerDelegate: CastDeviceScannerDelegate, @unchecked Sendable {
        weak var manager: CastManager?

        init(manager: CastManager) {
            self.manager = manager
        }

        func deviceDidComeOnline(_ device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let self, let manager = self.manager else { return }
                manager.availableDevices = manager.scanner.devices
            }
        }

        func deviceDidChange(_ device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let self, let manager = self.manager else { return }
                manager.availableDevices = manager.scanner.devices
            }
        }

        func deviceDidGoOffline(_ device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let self, let manager = self.manager else { return }
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
                manager.player?.muteForCast()
                manager.isConnected = true
                manager.connectedDeviceName = device.name
                manager.isCastPlaying = true
                manager.castStream()
            }
        }

        func castClient(_ client: CastClient, didDisconnectFrom device: CastDevice) {
            Task { @MainActor [weak self] in
                guard let manager = self?.manager else { return }
                manager.isConnected = false
                manager.connectedDeviceName = nil
                manager.isCastPlaying = false
                manager.player?.unmuteFromCast()
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

        func castClient(_ client: CastClient, mediaStatusDidChange status: CastMediaStatus) {}
    }
}

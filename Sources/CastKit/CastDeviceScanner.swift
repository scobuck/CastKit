import Foundation
import os
import Network

/// Context passed through the DNS-SD resolve callback.
private final class ResolveContext: @unchecked Sendable {
  let serviceName: String
  weak var scanner: CastDeviceScanner?

  init(serviceName: String, scanner: CastDeviceScanner) {
    self.serviceName = serviceName
    self.scanner = scanner
  }
}

public final class CastDeviceScanner: @unchecked Sendable {
  public weak var delegate: CastDeviceScannerDelegate?

  public static let deviceListDidChange = Notification.Name(rawValue: "DeviceScannerDeviceListDidChangeNotification")

  private var browser: NWBrowser?

  public var isScanning = false

  /// Maps service name → device id for handling removals.
  private var serviceDeviceMap = [String: String]()

  /// Active DNS-SD resolve operations.
  private var activeResolves = [String: DNSServiceRef]()
  /// Contexts kept alive during resolution (prevent ARC deallocation).
  private var resolveContexts = [String: ResolveContext]()

  public private(set) var devices = [CastDevice]() {
    didSet {
      NotificationCenter.default.post(name: CastDeviceScanner.deviceListDidChange, object: self)
    }
  }

  public func startScanning() {
    guard !isScanning else { return }

    setupAndStartBrowser()

    Log.discovery.debug("started scanning for _googlecast._tcp")
  }

  /// Stops the current scan and starts a fresh one, even if already scanning.
  public func restartScanning() {
    Log.discovery.debug("restarting scan (was scanning: \(self.isScanning), devices: \(self.devices.count))")

    browser?.cancel()
    browser = nil
    isScanning = false
    cancelAllResolves()
    devices.removeAll()
    serviceDeviceMap.removeAll()
    setupAndStartBrowser()
  }

  /// Stops browsing. The devices found so far are kept, so a picker
  /// reopened a moment later shows them at once.
  public func stopScanning() {
    guard isScanning || browser != nil else { return }

    browser?.cancel()
    browser = nil
    isScanning = false
    cancelAllResolves()

    Log.discovery.debug("stopped scanning")
  }

  public func reset() {
    stopScanning()
    devices.removeAll()
    serviceDeviceMap.removeAll()
  }

  deinit {
    browser?.cancel()
    for (_, ref) in activeResolves { DNSServiceRefDeallocate(ref) }
  }

  // MARK: - NWBrowser Setup

  private func setupAndStartBrowser() {
    let params = NWParameters()
    // Cast devices sit on the infrastructure network. Peer-to-peer
    // (AWDL) browsing finds nothing extra and costs Wi-Fi throughput and
    // battery for as long as the browser runs.
    params.includePeerToPeer = false

    let newBrowser = NWBrowser(for: .bonjour(type: "_googlecast._tcp.", domain: "local."), using: params)

    newBrowser.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.isScanning = true
        Log.discovery.debug("browser ready")
      case .waiting(let error):
        // Browsing can't proceed — local network access denied, or no
        // network. Left as "searching…" forever, nobody knew.
        self.isScanning = false
        Log.discovery.debug("browser waiting: \(String(describing: error), privacy: .public)")
        self.delegate?.scannerDidFail(Self.describe(error))
      case .failed(let error):
        self.isScanning = false
        Log.discovery.error("browser failed: \(String(describing: error), privacy: .public)")
        self.delegate?.scannerDidFail(Self.describe(error))
      case .cancelled:
        self.isScanning = false
      default:
        break
      }
    }

    newBrowser.browseResultsChangedHandler = { [weak self] _, changes in
      guard let self else { return }
      for change in changes {
        switch change {
        case .added(let result):
          self.handleServiceAdded(result)
        case .removed(let result):
          self.handleServiceRemoved(result)
        case .changed(old: _, new: let result, flags: _):
          self.handleServiceAdded(result)
        case .identical:
          break
        @unknown default:
          break
        }
      }
    }

    newBrowser.start(queue: .main)
    self.browser = newBrowser
  }

  private static func describe(_ error: NWError) -> String {
    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
      return "Local network access is off for this app. Turn it on in Settings › Privacy & Security › Local Network."
    }
    return "Can't search for Cast devices right now (\(error.localizedDescription))."
  }

  // MARK: - Browse Result Handling

  private func handleServiceAdded(_ result: NWBrowser.Result) {
    guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

    Log.discovery.debug("found service \(name, privacy: .private)")

    cancelResolve(name: name)
    resolveService(name: name, type: type, domain: domain)
  }

  private func handleServiceRemoved(_ result: NWBrowser.Result) {
    guard case .service(let name, _, _, _) = result.endpoint else { return }

    Log.discovery.debug("removed service \(name, privacy: .private)")

    cancelResolve(name: name)

    guard let deviceId = serviceDeviceMap.removeValue(forKey: name),
      let index = devices.firstIndex(where: { $0.id == deviceId }) else { return }

    Log.discovery.debug("removing device \(self.devices[index].name, privacy: .private)")
    let device = devices.remove(at: index)
    delegate?.deviceDidGoOffline(device)
  }

  // MARK: - DNS-SD Resolution

  private func resolveService(name: String, type: String, domain: String) {
    let context = ResolveContext(serviceName: name, scanner: self)
    resolveContexts[name] = context
    let contextPtr = Unmanaged.passUnretained(context).toOpaque()

    var ref: DNSServiceRef?
    let err = DNSServiceResolve(
      &ref, 0, 0,
      name, type, domain,
      { (_, _, _, errorCode, _, hosttarget, port, txtLen, txtRecord, ctx) in
        guard errorCode == kDNSServiceErr_NoError,
              let hosttarget, let ctx else { return }

        let context = Unmanaged<ResolveContext>.fromOpaque(ctx).takeUnretainedValue()
        let hostname = String(cString: hosttarget)
        let resolvedPort = Int(UInt16(bigEndian: port))

        // Parse DNS-SD TXT record: sequence of length-prefixed "key=value" entries
        var txtInfo = [String: String]()
        if let txtRecord, txtLen > 0 {
          let data = Data(bytes: txtRecord, count: Int(txtLen))
          var offset = 0
          while offset < data.count {
            let len = Int(data[offset])
            offset += 1
            guard len > 0, offset + len <= data.count else { break }
            let entryData = data[offset..<(offset + len)]
            if let entry = String(data: entryData, encoding: .utf8),
               let eqIndex = entry.firstIndex(of: "=") {
              let key = String(entry[entry.startIndex..<eqIndex])
              let value = String(entry[entry.index(after: eqIndex)...])
              txtInfo[key] = value
            }
            offset += len
          }
        }

        let serviceName = context.serviceName

        DispatchQueue.main.async {
          guard let scanner = context.scanner else { return }
          scanner.cancelResolve(name: serviceName)
          scanner.handleResolved(serviceName: serviceName, hostname: hostname, port: resolvedPort, txtInfo: txtInfo)
        }
      },
      contextPtr
    )

    guard err == kDNSServiceErr_NoError, let ref else {
      Log.discovery.debug("resolve failed for \(name, privacy: .private): error \(err)")
      resolveContexts.removeValue(forKey: name)
      return
    }

    activeResolves[name] = ref
    DNSServiceSetDispatchQueue(ref, .main)
  }

  // MARK: - Device Construction

  private func handleResolved(serviceName: String, hostname: String, port: Int, txtInfo: [String: String]) {
    guard let id = txtInfo["id"], !id.isEmpty else {
      Log.discovery.debug("no id in the TXT record of \(serviceName, privacy: .private), skipped")
      return
    }

    let device = CastDevice(
      id: id,
      name: txtInfo["fn"] ?? serviceName,
      modelName: txtInfo["md"] ?? "Google Cast",
      hostName: hostname,
      ipAddress: hostname,
      port: port,
      capabilitiesMask: txtInfo["ca"].flatMap(Int.init) ?? 0,
      status: txtInfo["rs"] ?? "",
      iconPath: txtInfo["ic"] ?? ""
    )

    Log.discovery.debug("adding device \(device.name, privacy: .private) (\(device.modelName, privacy: .public))")

    serviceDeviceMap[serviceName] = device.id

    if let index = devices.firstIndex(where: { $0.id == device.id }) {
      let existing = devices[index]

      guard existing.name != device.name || existing.hostName != device.hostName else { return }

      devices.remove(at: index)
      devices.insert(device, at: index)

      delegate?.deviceDidChange(device)
    } else {
      devices.append(device)
      delegate?.deviceDidComeOnline(device)
    }
  }

  // MARK: - Cleanup

  fileprivate func cancelResolve(name: String) {
    if let ref = activeResolves.removeValue(forKey: name) {
      DNSServiceRefDeallocate(ref)
    }
    resolveContexts.removeValue(forKey: name)
  }

  private func cancelAllResolves() {
    for (_, ref) in activeResolves {
      DNSServiceRefDeallocate(ref)
    }
    activeResolves.removeAll()
    resolveContexts.removeAll()
  }
}

public protocol CastDeviceScannerDelegate: AnyObject {
  func deviceDidComeOnline(_ device: CastDevice)
  func deviceDidChange(_ device: CastDevice)
  func deviceDidGoOffline(_ device: CastDevice)
  /// Browsing can't proceed; `message` says why, in words for the user.
  func scannerDidFail(_ message: String)
}

public extension CastDeviceScannerDelegate {
  func scannerDidFail(_ message: String) {}
}

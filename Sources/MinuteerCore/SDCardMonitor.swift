import Foundation
import AppKit

public enum SDCardStatus: Equatable, Sendable {
    case notInserted
    case inserted(volumeURL: URL, freeBytes: Int64, totalBytes: Int64)
}

public final class SDCardMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _targetVolumeName: String

    public var targetVolumeName: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _targetVolumeName
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _targetVolumeName = newValue
        }
    }

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var observers: [@Sendable (SDCardStatus) -> Void] = []

    public func addObserver(_ observer: @escaping @Sendable (SDCardStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        observers.append(observer)
    }

    public var onStatusChanged: (@Sendable (SDCardStatus) -> Void)? {
        get { nil }
        set {
            if let newValue = newValue {
                addObserver(newValue)
            }
        }
    }

    var ejectHandler: (@Sendable (URL) throws -> Void)?
    private(set) public var currentStatus: SDCardStatus = .notInserted

    public init(targetVolumeName: String = "P2_SD") {
        self._targetVolumeName = targetVolumeName
    }

    deinit {
        stopMonitoring()
    }

    public func isTargetVolume(url: URL, name: String) -> Bool {
        return name.caseInsensitiveCompare(targetVolumeName) == .orderedSame ||
               url.lastPathComponent.caseInsensitiveCompare(targetVolumeName) == .orderedSame
    }

    public func startMonitoring() {
        checkCurrentVolumes()

        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMountNotification(notification)
        }

        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUnmountNotification(notification)
        }
    }

    public func stopMonitoring() {
        if let observer = mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            mountObserver = nil
        }
        if let observer = unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            unmountObserver = nil
        }
    }

    public func checkCurrentVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else {
            updateStatus(.notInserted)
            return
        }

        for volumeURL in mountedVolumeURLs {
            if let values = try? volumeURL.resourceValues(forKeys: Set(keys)),
               let volumeName = values.volumeName,
               isTargetVolume(url: volumeURL, name: volumeName) {
                var total: Int64 = 0
                if let cap = values.volumeTotalCapacity {
                    total = Int64(cap)
                }
                var free: Int64 = 0
                if let avail = values.volumeAvailableCapacity {
                    free = Int64(avail)
                } else if let avail = values.volumeAvailableCapacityForImportantUsage {
                    free = avail
                }
                updateStatus(.inserted(volumeURL: volumeURL, freeBytes: free, totalBytes: total))
                return
            }
        }

        updateStatus(.notInserted)
    }

    func handleMountNotification(_ notification: Notification) {
        let volumeURL: URL?
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            volumeURL = url
        } else if let path = notification.userInfo?["NSDevicePath"] as? String {
            volumeURL = URL(fileURLWithPath: path)
        } else {
            volumeURL = nil
        }

        if let volumeURL = volumeURL {
            var volumeName = volumeURL.lastPathComponent
            if let name = (try? volumeURL.resourceValues(forKeys: [.volumeNameKey]))?.volumeName {
                volumeName = name
            }

            if isTargetVolume(url: volumeURL, name: volumeName) {
                let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
                let values = try? volumeURL.resourceValues(forKeys: Set(keys))
                var total: Int64 = 0
                if let cap = values?.volumeTotalCapacity {
                    total = Int64(cap)
                }
                var free: Int64 = 0
                if let avail = values?.volumeAvailableCapacity {
                    free = Int64(avail)
                } else if let avail = values?.volumeAvailableCapacityForImportantUsage {
                    free = avail
                }
                updateStatus(.inserted(volumeURL: volumeURL, freeBytes: free, totalBytes: total))
                return
            }
        }

        checkCurrentVolumes()
    }

    func handleUnmountNotification(_ notification: Notification) {
        let unmountedURL: URL?
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            unmountedURL = url
        } else if let path = notification.userInfo?["NSDevicePath"] as? String {
            unmountedURL = URL(fileURLWithPath: path)
        } else {
            unmountedURL = nil
        }

        if case .inserted(let url, _, _) = currentStatus, let unmounted = unmountedURL, unmounted.path == url.path {
            updateStatus(.notInserted)
            return
        }
        checkCurrentVolumes()
    }

    func updateStatus(_ newStatus: SDCardStatus) {
        lock.lock()
        currentStatus = newStatus
        let currentObservers = observers
        lock.unlock()

        for observer in currentObservers {
            observer(newStatus)
        }
    }

    @MainActor
    public func ejectCard() async throws {
        if case .notInserted = currentStatus {
            checkCurrentVolumes()
        }
        guard case .inserted(let volumeURL, _, _) = currentStatus else {
            return
        }

        if let handler = ejectHandler {
            try handler(volumeURL)
        } else {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
        }
        updateStatus(.notInserted)
    }

    public func deleteAudioFile(_ file: AudioRecordingFile) throws {
        guard case .inserted(let volumeURL, _, _) = currentStatus else {
            throw NSError(domain: "SDCardMonitor", code: 404, userInfo: [NSLocalizedDescriptionKey: "SD Card is not inserted"])
        }

        // Data Safety: Ensure the target file is actually on the SD card volume
        guard file.url.path.hasPrefix(volumeURL.path) else {
            throw NSError(domain: "SDCardMonitor", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security error: File is not located on the SD card volume."])
        }

        // Move to trash or remove
        try FileManager.default.removeItem(at: file.url)
    }
}

import Foundation

public final class WatchFolderMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _watchDirectoryURL: URL?
    private var _isEnabled: Bool = false

    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var timerSource: (any DispatchSourceTimer)?
    private let queue = DispatchQueue(label: "com.minuteer.watchfolder", qos: .utility)
    private var fileDescriptor: Int32 = -1

    public var onFilesDiscovered: (@Sendable ([URL]) -> Void)?

    public var watchDirectoryURL: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _watchDirectoryURL
        }
        set {
            lock.lock()
            let changed = _watchDirectoryURL != newValue
            _watchDirectoryURL = newValue
            let running = _isEnabled
            lock.unlock()

            if changed && running {
                restartMonitoring()
            }
        }
    }

    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            let changed = _isEnabled != newValue
            _isEnabled = newValue
            lock.unlock()

            if changed {
                if newValue {
                    startMonitoring()
                } else {
                    stopMonitoring()
                }
            }
        }
    }

    public init(watchDirectoryURL: URL? = nil, isEnabled: Bool = false) {
        self._watchDirectoryURL = watchDirectoryURL
        self._isEnabled = isEnabled
        if isEnabled && watchDirectoryURL != nil {
            startMonitoring()
        }
    }

    deinit {
        stopMonitoring()
    }

    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        _isEnabled = true
        setupMonitoring()
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        _isEnabled = false
        tearDownMonitoring()
    }

    private func restartMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        tearDownMonitoring()
        if _isEnabled {
            setupMonitoring()
        }
    }

    private func setupMonitoring() {
        guard let url = _watchDirectoryURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        fileDescriptor = open(url.path, O_EVTONLY)
        if fileDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .link, .rename],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scanWatchedDirectory()
            }
            source.setCancelHandler { [weak self] in
                guard let self = self else { return }
                if self.fileDescriptor >= 0 {
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
            }
            source.resume()
            directorySource = source
        }

        // Periodic polling timer (safety net for network shares / external syncs)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 4.0)
        timer.setEventHandler { [weak self] in
            self?.scanWatchedDirectory()
        }
        timer.resume()
        timerSource = timer

        // Initial scan
        queue.async { [weak self] in
            self?.scanWatchedDirectory()
        }
    }

    private func tearDownMonitoring() {
        if let source = directorySource {
            source.cancel()
            directorySource = nil
        }
        if let timer = timerSource {
            timer.cancel()
            timerSource = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    public func scanWatchedDirectory() {
        guard let dirURL = watchDirectoryURL, FileManager.default.fileExists(atPath: dirURL.path) else {
            return
        }

        let audioScanner = AudioScanner()
        let discovered = audioScanner.scanDirectory(at: dirURL)
        let readyURLs = discovered.map(\.url).filter { url in
            // Filter out temporary/incomplete files (e.g. .download, .crdownload, .tmp, or zero bytes)
            let ext = url.pathExtension.lowercased()
            if ext == "download" || ext == "tmp" || ext == "crdownload" {
                return false
            }
            let size = AudioFileCopyService.fileSize(at: url)
            return size > 0
        }

        if !readyURLs.isEmpty {
            onFilesDiscovered?(readyURLs)
        }
    }
}

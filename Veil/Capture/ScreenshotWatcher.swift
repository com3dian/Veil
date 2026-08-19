import Foundation

/// Watches the macOS Screenshots folder (Desktop by default) for new screenshot files.
final class ScreenshotWatcher {
    private var stream: FSEventStreamRef?
    private let onScreenshot: (URL) -> Void
    private var knownPaths = Set<String>()
    private let queue = DispatchQueue(label: "com.veil.screenshot-watcher")
    private var startedAt = Date()

    init(onScreenshot: @escaping (URL) -> Void) {
        self.onScreenshot = onScreenshot
    }

    func start() {
        stop()
        startedAt = Date()
        knownPaths = Set(existingScreenshotPaths())

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = screenshotDirectories() as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
                for index in 0..<numEvents {
                    let flag = eventFlags[index]
                    let createdOrRenamed =
                        (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
                        || (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
                    guard createdOrRenamed,
                          let path = paths[index] as? String else { continue }
                    watcher.handlePath(path)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private func handlePath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard isScreenshotFile(url) else { return }
        // Debounce duplicates and ignore files that already existed at launch.
        if knownPaths.contains(path) { return }
        knownPaths.insert(path)

        // Wait briefly so the screenshot write finishes.
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
            // Ignore ancient files that somehow re-fire.
            if let values = try? url.resourceValues(forKeys: [.creationDateKey]),
               let created = values.creationDate,
               created < self.startedAt.addingTimeInterval(-2) {
                return
            }
            self.onScreenshot(url)
        }
    }

    private func screenshotDirectories() -> [String] {
        var dirs: [String] = []
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if let desktop {
            dirs.append(desktop.path)
        }
        // Respect macOS "Save screenshots to" location when available.
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !custom.isEmpty {
            dirs.append((custom as NSString).expandingTildeInPath)
        }
        return Array(Set(dirs))
    }

    private func existingScreenshotPaths() -> [String] {
        screenshotDirectories().flatMap { dir -> [String] in
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
            return files.compactMap { name in
                let path = (dir as NSString).appendingPathComponent(name)
                return isScreenshotFile(URL(fileURLWithPath: path)) ? path : nil
            }
        }
    }

    private func isScreenshotFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) else { return false }
        // English + localized common prefixes; also accept Screen Recording stills are out of scope.
        let lowered = name.lowercased()
        return lowered.hasPrefix("screen shot")
            || lowered.hasPrefix("screenshot")
            || lowered.hasPrefix("屏幕快照")
            || lowered.hasPrefix("スクリーンショット")
            || name.hasPrefix("Capture d’écran")
            || name.hasPrefix("Captura de pantalla")
    }
}

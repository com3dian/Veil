import Foundation
import AppKit

/// Watches user-granted screenshot directories for new screenshot files.
/// Under App Sandbox the user must explicitly grant folder access via an open panel;
/// we persist that grant as a security-scoped bookmark.
final class ScreenshotWatcher {
    private var stream: FSEventStreamRef?
    private let onScreenshot: (URL) -> Void
    private var knownPaths = Set<String>()
    private let queue = DispatchQueue(label: "com.veil.screenshot-watcher")
    private var startedAt = Date()
    private var watchedURL: URL?

    private static let bookmarkKey = "ScreenshotFolderBookmark"

    init(onScreenshot: @escaping (URL) -> Void) {
        self.onScreenshot = onScreenshot
    }

    /// Attempts to restore a previously bookmarked folder. Returns true if successful.
    func restoreBookmarkedFolder() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }

        if isStale {
            saveBookmark(for: url)
        }

        guard url.startAccessingSecurityScopedResource() else { return false }
        watchedURL = url
        return true
    }

    /// Presents an open panel so the user can grant access to their screenshot folder.
    func requestFolderAccess(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Select the folder where macOS saves screenshots (usually Desktop)."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                completion(false)
                return
            }
            self.saveBookmark(for: url)
            guard url.startAccessingSecurityScopedResource() else {
                completion(false)
                return
            }
            self.watchedURL = url
            completion(true)
        }
    }

    func start() {
        stop()
        guard let dir = watchedURL else { return }

        startedAt = Date()
        knownPaths = Set(existingScreenshotPaths(in: dir))

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [dir.path] as CFArray
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
        watchedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Private

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    private func handlePath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard isScreenshotFile(url) else { return }
        if knownPaths.contains(path) { return }
        knownPaths.insert(path)

        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
            if let values = try? url.resourceValues(forKeys: [.creationDateKey]),
               let created = values.creationDate,
               created < self.startedAt.addingTimeInterval(-2) {
                return
            }
            self.onScreenshot(url)
        }
    }

    private func existingScreenshotPaths(in dir: URL) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { name in
            let path = dir.appendingPathComponent(name).path
            return isScreenshotFile(URL(fileURLWithPath: path)) ? path : nil
        }
    }

    private func isScreenshotFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) else { return false }
        let lowered = name.lowercased()
        return lowered.hasPrefix("screen shot")
            || lowered.hasPrefix("screenshot")
            || lowered.hasPrefix("屏幕快照")
            || lowered.hasPrefix("スクリーンショット")
            || name.hasPrefix("Capture d'écran")
            || name.hasPrefix("Captura de pantalla")
    }
}

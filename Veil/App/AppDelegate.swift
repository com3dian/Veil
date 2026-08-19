import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var screenshotWatcher: ScreenshotWatcher?
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(
            onOpenImage: { [weak self] in self?.openImagePanel() },
            onToggleWatching: { [weak self] enabled in self?.setWatching(enabled) },
            onQuit: { NSApp.terminate(nil) }
        )

        setWatching(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let image = NSImage(contentsOf: url) else { return }
        presentEditor(with: image, sourceURL: url)
    }

    private func setWatching(_ enabled: Bool) {
        if enabled {
            if screenshotWatcher == nil {
                let watcher = ScreenshotWatcher { [weak self] url in
                    DispatchQueue.main.async {
                        guard let image = NSImage(contentsOf: url) else { return }
                        self?.presentEditor(with: image, sourceURL: url)
                    }
                }
                if watcher.restoreBookmarkedFolder() {
                    watcher.start()
                } else {
                    watcher.requestFolderAccess { granted in
                        if granted { watcher.start() }
                    }
                }
                screenshotWatcher = watcher
            }
        } else {
            screenshotWatcher?.stop()
            screenshotWatcher = nil
        }
        menuBar.setWatching(enabled)
    }

    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        presentEditor(with: image, sourceURL: url)
    }

    private func presentEditor(with image: NSImage, sourceURL: URL?) {
        if editor == nil {
            editor = EditorWindowController()
            editor?.onClose = { [weak self] in
                self?.editor = nil
            }
        }
        editor?.present(image: image, sourceURL: sourceURL)
        NSApp.activate(ignoringOtherApps: true)
    }
}

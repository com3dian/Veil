import AppKit

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onOpenImage: () -> Void
    private let onToggleWatching: (Bool) -> Void
    private let onQuit: () -> Void
    private var watching = true

    init(
        onOpenImage: @escaping () -> Void,
        onToggleWatching: @escaping (Bool) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenImage = onOpenImage
        self.onToggleWatching = onToggleWatching
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(named: "menubaricon")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Veil"
        }
        rebuildMenu()
    }

    func setWatching(_ enabled: Bool) {
        watching = enabled
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Image…", action: #selector(handleOpen), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let watchTitle = watching ? "Pause Screenshot Watch" : "Resume Screenshot Watch"
        let watch = NSMenuItem(title: watchTitle, action: #selector(handleToggleWatch), keyEquivalent: "")
        watch.target = self
        menu.addItem(watch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Veil", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func handleOpen() {
        onOpenImage()
    }

    @objc private func handleToggleWatch() {
        onToggleWatching(!watching)
    }

    @objc private func handleQuit() {
        onQuit()
    }
}

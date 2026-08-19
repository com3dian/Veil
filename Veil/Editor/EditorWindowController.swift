import AppKit
import MetalKit

enum EditorTool: Int {
    case paint
    case erase
    case adjust
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var sourceURL: URL?
    private var canvas: EditorCanvasView!
    private var toolSegment: NSSegmentedControl!
    private var brushSlider: NSSlider!
    private var featherSlider: NSSlider!
    private var blurSlider: NSSlider!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Veil"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func present(image: NSImage, sourceURL: URL?) {
        self.sourceURL = sourceURL
        window?.title = sourceURL?.lastPathComponent ?? "Veil — Clipboard"
        canvas.load(image: image)
        canvas.setBlur(Float(blurSlider.doubleValue))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        let metalView = MTKView(frame: .zero)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        root.addSubview(metalView)

        canvas = EditorCanvasView(metalView: metalView)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        // Overlay transparent interaction view on top of metal.
        let interaction = canvas!
        interaction.wantsLayer = true
        root.addSubview(interaction)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            metalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            metalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            interaction.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            interaction.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            interaction.topAnchor.constraint(equalTo: metalView.topAnchor),
            interaction.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
        ])

        window.contentView = root
    }

    private func makeToolbar() -> NSView {
        let bar = NSView()

        toolSegment = NSSegmentedControl(
            labels: ["Paint", "Erase", "Adjust"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(toolChanged)
        )
        toolSegment.selectedSegment = 0
        toolSegment.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(toolSegment)

        let brushLabel = label("Brush")
        brushSlider = NSSlider(value: 28, minValue: 4, maxValue: 120, target: self, action: #selector(brushChanged))
        brushSlider.translatesAutoresizingMaskIntoConstraints = false
        brushLabel.translatesAutoresizingMaskIntoConstraints = false

        let featherLabel = label("Feather")
        featherSlider = NSSlider(value: 10, minValue: 1, maxValue: 40, target: self, action: #selector(featherChanged))
        featherSlider.translatesAutoresizingMaskIntoConstraints = false
        featherLabel.translatesAutoresizingMaskIntoConstraints = false

        let blurLabel = label("Blur")
        blurSlider = NSSlider(value: 18, minValue: 0, maxValue: 64, target: self, action: #selector(blurChanged))
        blurSlider.translatesAutoresizingMaskIntoConstraints = false
        blurLabel.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear Mask", target: self, action: #selector(clearMask))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyResult))
        copy.bezelStyle = .rounded
        copy.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Save…", target: self, action: #selector(saveResult))
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false

        // Keep action buttons from sliding under the sliders when the window narrows.
        [clear, copy, save].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        [brushSlider, featherSlider, blurSlider].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        bar.addSubview(brushLabel)
        bar.addSubview(brushSlider)
        bar.addSubview(featherLabel)
        bar.addSubview(featherSlider)
        bar.addSubview(blurLabel)
        bar.addSubview(blurSlider)
        bar.addSubview(clear)
        bar.addSubview(copy)
        bar.addSubview(save)

        NSLayoutConstraint.activate([
            toolSegment.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            toolSegment.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            brushLabel.leadingAnchor.constraint(equalTo: toolSegment.trailingAnchor, constant: 14),
            brushLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            brushSlider.leadingAnchor.constraint(equalTo: brushLabel.trailingAnchor, constant: 6),
            brushSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            brushSlider.widthAnchor.constraint(equalToConstant: 90),

            featherLabel.leadingAnchor.constraint(equalTo: brushSlider.trailingAnchor, constant: 12),
            featherLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            featherSlider.leadingAnchor.constraint(equalTo: featherLabel.trailingAnchor, constant: 6),
            featherSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            featherSlider.widthAnchor.constraint(equalToConstant: 80),

            blurLabel.leadingAnchor.constraint(equalTo: featherSlider.trailingAnchor, constant: 12),
            blurLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            blurSlider.leadingAnchor.constraint(equalTo: blurLabel.trailingAnchor, constant: 6),
            blurSlider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            blurSlider.widthAnchor.constraint(equalToConstant: 70),

            clear.leadingAnchor.constraint(greaterThanOrEqualTo: blurSlider.trailingAnchor, constant: 12),
            save.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            save.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            copy.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            copy.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        return bar
    }

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .medium)
        f.textColor = .secondaryLabelColor
        return f
    }

    @objc private func toolChanged() {
        let tool = EditorTool(rawValue: toolSegment.selectedSegment) ?? .paint
        // Mask tint is for paint/erase feedback; Adjust uses the hover border only.
        canvas.setShowMask(tool != .adjust)
        canvas.tool = tool
    }

    @objc private func brushChanged() {
        canvas.brushRadius = CGFloat(brushSlider.doubleValue)
    }

    @objc private func featherChanged() {
        canvas.feather = Float(featherSlider.doubleValue)
    }

    @objc private func blurChanged() {
        canvas.setBlur(Float(blurSlider.doubleValue))
    }

    @objc private func clearMask() {
        canvas.clearMask()
    }

    @objc private func copyResult() {
        guard let image = canvas.exportImage() else { return }
        ImageExporter.copyToPasteboard(image)
    }

    @objc private func saveResult() {
        guard let image = canvas.exportImage() else { return }
        ImageExporter.savePanel(for: image, suggestedURL: sourceURL)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

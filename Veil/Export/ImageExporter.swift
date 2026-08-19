import AppKit
import UniformTypeIdentifiers

enum ImageExporter {
    @discardableResult
    static func copyToPasteboard(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        if let png = pngData(from: image) {
            pb.setData(png, forType: .png)
        }
        return true
    }

    static func savePanel(for image: NSImage, suggestedURL: URL?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedURL?.deletingPathExtension().lastPathComponent.appending("-veil.png")
            ?? "veil-edit.png"
        if let dir = suggestedURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = pngData(from: image) else { return }
        try? data.write(to: url)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let cg = image.veil_cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}

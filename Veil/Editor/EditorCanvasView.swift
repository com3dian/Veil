import AppKit
import MetalKit

/// Transparent interaction layer over the Metal preview.
final class EditorCanvasView: NSView {
    var tool: EditorTool = .paint {
        didSet {
            guard tool != oldValue else { return }
            // Thin yellow isocontour appears only while hovering the edge;
            // dash gaps fill solid under the cursor.
            renderer.setBorderHighlight(enabled: tool == .adjust)
            if tool != .adjust {
                cancelAdjustInteraction()
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Brush radius in view points (converted to image pixels while painting).
    var brushRadius: CGFloat = 28
    var brushHardness: CGFloat = 0.35
    var feather: Float = 10 {
        didSet {
            renderer?.setFeather(feather)
        }
    }

    private let metalView: MTKView
    private var renderer: WarpRenderer!
    private var maskBuffer: MaskBuffer?
    private var lastPaintPoint: CGPoint?

    private var isHoveringEdge = false
    private var isDraggingEdge = false
    private var lastDragPoint: CGPoint?

    init(metalView: MTKView) {
        self.metalView = metalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        guard let renderer = WarpRenderer(metalView: metalView) else {
            fatalError("Metal is required for Veil")
        }
        self.renderer = renderer
        renderer.setFeather(feather)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    func load(image: NSImage) {
        renderer.load(image: image)
        maskBuffer = MaskBuffer(width: renderer.imageWidth, height: renderer.imageHeight)
        renderer.setWarpAmount(0)
        renderer.setFeather(feather)
        renderer.setShowMask(true)
        cancelAdjustInteraction()
    }

    func clearMask() {
        maskBuffer?.clear()
        renderer.clearMask()
        renderer.setWarpAmount(0)
        cancelAdjustInteraction()
    }

    func setShowMask(_ show: Bool) {
        renderer.setShowMask(show)
    }

    func setBlur(_ radius: Float) {
        renderer.setBlurRadius(radius)
    }

    func reprocessMask() {
        renderer.setFeather(feather)
    }

    func exportImage() -> NSImage? {
        renderer.exportImage()
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        guard tool == .adjust, !isDraggingEdge else { return }
        updateEdgeHover(at: imagePoint(from: event))
    }

    override func cursorUpdate(with event: NSEvent) {
        if tool == .adjust && (isHoveringEdge || isDraggingEdge) {
            (isDraggingEdge ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(from: event)
        switch tool {
        case .paint, .erase:
            lastPaintPoint = p
            let dirty = maskBuffer?.stamp(
                at: p,
                radius: imageSpaceBrushRadius(),
                hardness: brushHardness,
                erase: tool == .erase
            ) ?? .empty()
            publishPaintPreview(dirty: dirty)
        case .adjust:
            // Only start a drag when the click actually lands on the edge band.
            guard let maskBuffer,
                  isOnEdgeBand(p, in: maskBuffer) else {
                return
            }
            isDraggingEdge = true
            isHoveringEdge = true
            lastDragPoint = p
            maskBuffer.beginEdgeGrab(at: p)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(from: event)
        switch tool {
        case .paint, .erase:
            let radius = imageSpaceBrushRadius()
            let dirty: DirtyRect
            if let last = lastPaintPoint {
                dirty = maskBuffer?.stroke(
                    from: last,
                    to: p,
                    radius: radius,
                    hardness: brushHardness,
                    erase: tool == .erase
                ) ?? .empty()
            } else {
                dirty = maskBuffer?.stamp(
                    at: p,
                    radius: radius,
                    hardness: brushHardness,
                    erase: tool == .erase
                ) ?? .empty()
            }
            lastPaintPoint = p
            publishPaintPreview(dirty: dirty)
        case .adjust:
            continueEdgeDrag(to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastPaintPoint = nil
        if tool == .adjust, isDraggingEdge {
            isDraggingEdge = false
            lastDragPoint = nil
            maskBuffer?.endEdgeGrab()
            updateEdgeHover(at: imagePoint(from: event))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard tool == .paint || tool == .erase else { return }
        brushRadius = min(160, max(4, brushRadius + event.scrollingDeltaY))
    }

    // MARK: - Adjust: GPU band for "where", direct coverage nudge for "how"

    private func cancelAdjustInteraction() {
        isDraggingEdge = false
        isHoveringEdge = false
        lastDragPoint = nil
        maskBuffer?.endEdgeGrab()
        renderer.setBorderCursor(imagePoint: .zero, solidRadius: 0, active: false)
        NSCursor.arrow.set()
    }

    /// Grab tolerance around the painted boundary (image pixels). Wider than
    /// the on-screen line so the thin contour stays easy to click.
    private func edgeGrabRadiusImage() -> CGFloat {
        max(6, imageSpaceBrushRadius() * 0.35)
    }

    /// How far along the border the dash gaps fill in under the cursor.
    private func edgeSolidRadiusImage() -> CGFloat {
        max(18, imageSpaceBrushRadius() * 0.85)
    }

    /// Small C¹ influence disk around the grab point (image pixels).
    private func edgeWarpRadiusImage() -> CGFloat {
        min(22, max(10, imageSpaceBrushRadius() * 0.4))
    }

    private func isOnEdgeBand(_ p: CGPoint, in maskBuffer: MaskBuffer) -> Bool {
        maskBuffer.boundaryBandValue(at: p, radius: edgeGrabRadiusImage()) > 0.08
    }

    private func updateEdgeHover(at p: CGPoint) {
        guard let maskBuffer else { return }
        let onEdge = isOnEdgeBand(p, in: maskBuffer)
        if isHoveringEdge != onEdge {
            isHoveringEdge = onEdge
            window?.invalidateCursorRects(for: self)
            if onEdge {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        // Always refresh cursor highlight so the solid segment tracks the mouse.
        renderer.setBorderCursor(
            imagePoint: p,
            solidRadius: edgeSolidRadiusImage(),
            active: onEdge || isDraggingEdge
        )
    }

    private func continueEdgeDrag(to p: CGPoint) {
        guard isDraggingEdge, let maskBuffer else { return }

        renderer.setBorderCursor(
            imagePoint: p,
            solidRadius: edgeSolidRadiusImage(),
            active: true
        )

        // Absolute Hermite C¹ warp from mouse-down: grab point tracks the
        // cursor; at the influence threshold u=∇u=0 so the join stays smooth.
        let dirty = maskBuffer.warpGrab(to: p, radius: edgeWarpRadiusImage())
        lastDragPoint = p
        guard !dirty.isEmpty else { return }
        renderer.updateCoveragePreview(coverage: maskBuffer.coverage, dirty: dirty)
    }

    // MARK: - Coordinate mapping

    private struct ImageLayout {
        let scale: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        let imgW: CGFloat
        let imgH: CGFloat
    }

    private func imageLayout() -> ImageLayout {
        let viewSize = bounds.size
        let imgW = CGFloat(renderer.imageWidth)
        let imgH = CGFloat(renderer.imageHeight)
        let scale = min(viewSize.width / max(imgW, 1), viewSize.height / max(imgH, 1))
        let drawW = imgW * scale
        let drawH = imgH * scale
        return ImageLayout(
            scale: max(scale, 0.0001),
            originX: (viewSize.width - drawW) * 0.5,
            originY: (viewSize.height - drawH) * 0.5,
            imgW: imgW,
            imgH: imgH
        )
    }

    private func imagePoint(from event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        let layout = imageLayout()
        let x = (loc.x - layout.originX) / layout.scale
        let yFromBottom = (loc.y - layout.originY) / layout.scale
        let y = layout.imgH - yFromBottom
        return CGPoint(x: x, y: y)
    }

    private func imageSpaceBrushRadius() -> CGFloat {
        brushRadius / imageLayout().scale
    }

    private func publishPaintPreview(dirty: DirtyRect) {
        guard let maskBuffer, !dirty.isEmpty else { return }
        renderer.updateCoveragePreview(coverage: maskBuffer.coverage, dirty: dirty)
    }
}

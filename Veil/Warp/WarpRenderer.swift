import AppKit
import Metal
import MetalKit
import simd

struct WarpUniforms {
    var amount: Float
    var blurRadius: Float
    var showMask: Float
    var feather: Float
    var width: Float
    var height: Float
    var viewWidth: Float
    var viewHeight: Float
    var showBorder: Float
    var borderCursorX: Float
    var borderCursorY: Float
    var borderHover: Float
    var borderSolidRadius: Float
}

struct FeatherUniforms {
    var feather: Float
    var width: Float
    var height: Float
}

struct BlurUniforms {
    var radius: Float
    var width: Float
    var height: Float
}

final class WarpRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let featherHPipeline: MTLComputePipelineState
    private let featherVPipeline: MTLComputePipelineState
    private let blurHPipeline: MTLComputePipelineState
    private let blurVPipeline: MTLComputePipelineState
    private weak var metalView: MTKView?

    private var sourceTexture: MTLTexture?
    private var coverageTexture: MTLTexture?
    private var featherTempTexture: MTLTexture?
    private var softAlphaTexture: MTLTexture?
    /// Separable blur scratch (RGBA16F).
    private var blurTempTexture: MTLTexture?
    /// Fully convolved Gaussian of the source image.
    private var blurredSourceTexture: MTLTexture?
    private var coveragePixels: [UInt8] = []
    private var softMaskDirty = true
    private var imageBlurDirty = true

    private var uniforms = WarpUniforms(
        amount: 0,
        blurRadius: 18,
        showMask: 1,
        feather: 10,
        width: 1,
        height: 1,
        viewWidth: 1,
        viewHeight: 1,
        showBorder: 0,
        borderCursorX: 0,
        borderCursorY: 0,
        borderHover: 0,
        borderSolidRadius: 24
    )

    private(set) var imageWidth: Int = 1
    private(set) var imageHeight: Int = 1

    init?(metalView: MTKView) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.metalView = metalView
        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        metalView.framebufferOnly = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true

        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        guard let library = try? device.makeLibrary(source: ShaderSource.metal, options: options),
              let vert = library.makeFunction(name: "veil_vertex"),
              let frag = library.makeFunction(name: "veil_warp_fragment"),
              let featherH = library.makeFunction(name: "veil_feather_h"),
              let featherV = library.makeFunction(name: "veil_feather_v"),
              let blurH = library.makeFunction(name: "veil_blur_h"),
              let blurV = library.makeFunction(name: "veil_blur_v") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            featherHPipeline = try device.makeComputePipelineState(function: featherH)
            featherVPipeline = try device.makeComputePipelineState(function: featherV)
            blurHPipeline = try device.makeComputePipelineState(function: blurH)
            blurVPipeline = try device.makeComputePipelineState(function: blurV)
        } catch {
            return nil
        }

        super.init()
        metalView.delegate = self
    }

    func load(image: NSImage) {
        guard let cg = image.veil_cgImage else { return }
        imageWidth = cg.width
        imageHeight = cg.height
        sourceTexture = Self.makeTexture(device: device, cgImage: cg)
        ensureMaskTextures()
        clearMask()
        uniforms.width = Float(imageWidth)
        uniforms.height = Float(imageHeight)
        imageBlurDirty = true
        redraw()
    }

    func clearMask() {
        ensureMaskTextures()
        for i in coveragePixels.indices { coveragePixels[i] = 0 }
        uploadCoverageFull()
        softMaskDirty = true
        redraw()
    }

    func updateCoveragePreview(coverage: [Float], dirty: DirtyRect) {
        precondition(coverage.count == imageWidth * imageHeight)
        ensureMaskTextures()
        let region = dirty.clamped(width: imageWidth, height: imageHeight)
        guard !region.isEmpty else { return }

        for y in region.minY...region.maxY {
            let row = y * imageWidth
            for x in region.minX...region.maxX {
                let i = row + x
                coveragePixels[i] = UInt8(min(max(coverage[i] * 255.0, 0), 255))
            }
        }
        uploadCoverage(region: region)
        softMaskDirty = true
        redraw()
    }

    func setWarpAmount(_ amount: Float) {
        uniforms.amount = amount
        redraw()
    }

    func setBlurRadius(_ radius: Float) {
        let newRadius = max(0, radius)
        if abs(newRadius - uniforms.blurRadius) > 0.01 {
            imageBlurDirty = true
        }
        uniforms.blurRadius = newRadius
        redraw()
    }

    func setFeather(_ feather: Float) {
        uniforms.feather = max(1, feather)
        softMaskDirty = true
        redraw()
    }

    func setShowMask(_ show: Bool) {
        uniforms.showMask = show ? 1 : 0
        redraw()
    }

    /// Draws a thin dashed isocontour on the painted-mask boundary (Adjust only).
    /// Hit-testing keeps its own wider CPU band separately.
    func setBorderHighlight(enabled: Bool) {
        uniforms.showBorder = enabled ? 1 : 0
        if !enabled {
            uniforms.borderHover = 0
        }
        redraw()
    }

    /// While hovering/dragging the border, fill dash gaps under the cursor so
    /// the outline reads as a solid line in that neighborhood.
    func setBorderCursor(imagePoint: CGPoint, solidRadius: CGFloat, active: Bool) {
        uniforms.borderCursorX = Float(imagePoint.x)
        uniforms.borderCursorY = Float(imagePoint.y)
        uniforms.borderSolidRadius = max(Float(solidRadius), 8)
        uniforms.borderHover = active ? 1 : 0
        redraw()
    }

    func redraw() {
        guard let metalView else { return }
        metalView.needsDisplay = true
        metalView.draw()
    }

    func exportImage() -> NSImage? {
        guard let sourceTexture, let softAlphaTexture, let blurredSourceTexture,
              let coverageTexture else { return nil }
        let width = imageWidth
        let height = imageHeight

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        encodeFeather(into: commandBuffer)
        encodeImageBlur(into: commandBuffer)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var u = uniforms
        u.showMask = 0
        u.showBorder = 0
        u.viewWidth = Float(width)
        u.viewHeight = Float(height)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(softAlphaTexture, index: 1)
        encoder.setFragmentTexture(blurredSourceTexture, index: 2)
        encoder.setFragmentTexture(coverageTexture, index: 3)
        encoder.setFragmentBytes(&u, length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let bufferSize = width * height * 4
        guard let readback = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return nil }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(width, height, 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: width * 4,
            destinationBytesPerImage: bufferSize
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let data = Data(bytes: readback.contents(), count: bufferSize)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    // MARK: - GPU feather

    private func encodeFeather(into commandBuffer: MTLCommandBuffer) {
        guard softMaskDirty,
              let coverageTexture,
              let featherTempTexture,
              let softAlphaTexture else { return }

        var feather = FeatherUniforms(
            feather: uniforms.feather,
            width: Float(imageWidth),
            height: Float(imageHeight)
        )
        let threads = MTLSize(width: imageWidth, height: imageHeight, depth: 1)

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(featherHPipeline)
            encoder.setTexture(coverageTexture, index: 0)
            encoder.setTexture(featherTempTexture, index: 1)
            encoder.setBytes(&feather, length: MemoryLayout<FeatherUniforms>.stride, index: 0)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tgSize(for: featherHPipeline))
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(featherVPipeline)
            encoder.setTexture(featherTempTexture, index: 0)
            encoder.setTexture(softAlphaTexture, index: 1)
            encoder.setBytes(&feather, length: MemoryLayout<FeatherUniforms>.stride, index: 0)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tgSize(for: featherVPipeline))
            encoder.endEncoding()
        }

        softMaskDirty = false
    }

    // MARK: - GPU image blur (separable convolution)

    private func encodeImageBlur(into commandBuffer: MTLCommandBuffer) {
        guard uniforms.blurRadius > 0.5 else { return }
        guard imageBlurDirty,
              let sourceTexture,
              let blurTempTexture,
              let blurredSourceTexture else { return }

        var blur = BlurUniforms(
            radius: uniforms.blurRadius,
            width: Float(imageWidth),
            height: Float(imageHeight)
        )
        let threads = MTLSize(width: imageWidth, height: imageHeight, depth: 1)

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(blurHPipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(blurTempTexture, index: 1)
            encoder.setBytes(&blur, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tgSize(for: blurHPipeline))
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(blurVPipeline)
            encoder.setTexture(blurTempTexture, index: 0)
            encoder.setTexture(blurredSourceTexture, index: 1)
            encoder.setBytes(&blur, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tgSize(for: blurVPipeline))
            encoder.endEncoding()
        }

        imageBlurDirty = false
    }

    private func tgSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let maxTotal = max(pipeline.maxTotalThreadsPerThreadgroup, 1)
        let w = 16
        let h = max(1, min(16, maxTotal / w))
        return MTLSize(width: w, height: h, depth: 1)
    }

    // MARK: - Texture helpers

    private func ensureMaskTextures() {
        let count = imageWidth * imageHeight
        if coveragePixels.count != count {
            coveragePixels = [UInt8](repeating: 0, count: count)
        }

        if coverageTexture?.width != imageWidth || coverageTexture?.height != imageHeight {
            coverageTexture = makeTexture(
                pixelFormat: .r8Unorm,
                usage: [.shaderRead],
                storage: .shared
            )
            featherTempTexture = makeTexture(
                pixelFormat: .r16Float,
                usage: [.shaderRead, .shaderWrite],
                storage: .private
            )
            softAlphaTexture = makeTexture(
                pixelFormat: .r8Unorm,
                usage: [.shaderRead, .shaderWrite],
                storage: .private
            )
            blurTempTexture = makeTexture(
                pixelFormat: .rgba16Float,
                usage: [.shaderRead, .shaderWrite],
                storage: .private
            )
            blurredSourceTexture = makeTexture(
                pixelFormat: .rgba16Float,
                usage: [.shaderRead, .shaderWrite],
                storage: .private
            )
            softMaskDirty = true
            imageBlurDirty = true
        }
    }

    private func makeTexture(
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        storage: MTLStorageMode
    ) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: imageWidth,
            height: imageHeight,
            mipmapped: false
        )
        desc.usage = usage
        desc.storageMode = storage
        return device.makeTexture(descriptor: desc)
    }

    private func uploadCoverageFull() {
        guard let coverageTexture else { return }
        coverageTexture.replace(
            region: MTLRegionMake2D(0, 0, imageWidth, imageHeight),
            mipmapLevel: 0,
            withBytes: coveragePixels,
            bytesPerRow: imageWidth
        )
    }

    private func uploadCoverage(region: DirtyRect) {
        guard let coverageTexture, !region.isEmpty else { return }
        let w = region.width
        let h = region.height
        var slice = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = (region.minY + row) * imageWidth + region.minX
            let dst = row * w
            slice.replaceSubrange(dst..<(dst + w), with: coveragePixels[src..<(src + w)])
        }
        coverageTexture.replace(
            region: MTLRegionMake2D(region.minX, region.minY, w, h),
            mipmapLevel: 0,
            withBytes: slice,
            bytesPerRow: w
        )
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.viewWidth = Float(size.width)
        uniforms.viewHeight = Float(size.height)
    }

    func draw(in view: MTKView) {
        uniforms.viewWidth = Float(view.drawableSize.width)
        uniforms.viewHeight = Float(view.drawableSize.height)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let sourceTexture,
              let softAlphaTexture,
              let blurredSourceTexture,
              let coverageTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        encodeFeather(into: commandBuffer)
        encodeImageBlur(into: commandBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(softAlphaTexture, index: 1)
        // When blur is off, still bind a valid texture; mix is skipped in shader.
        encoder.setFragmentTexture(blurredSourceTexture, index: 2)
        encoder.setFragmentTexture(coverageTexture, index: 3)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<WarpUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makeTexture(device: MTLDevice, cgImage: CGImage) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(
            cgImage: cgImage,
            options: [
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft as NSObject,
            ]
        )
    }
}

extension NSImage {
    var veil_cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
            ?? tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
    }
}

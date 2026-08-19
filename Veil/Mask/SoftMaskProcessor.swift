import CoreGraphics
import Foundation
import simd

struct SoftMaskResult {
    /// Soft alpha mask 0...1 after morphology + blur.
    var alpha: [Float]
    /// Unit normals in image space (x right, y down). Zero where gradient is tiny.
    var normals: [SIMD2<Float>]
    let width: Int
    let height: Int
}

enum SoftMaskProcessor {
    /// Build a natural soft boundary from raw brush coverage.
    /// Pipeline: close gaps → Gaussian blur → smoothstep → Sobel normals.
    static func process(
        coverage: [Float],
        width: Int,
        height: Int,
        feather: Float = 8,
        closeRadius: Int = 2
    ) -> SoftMaskResult {
        precondition(coverage.count == width * height)

        var closed = coverage
        if closeRadius > 0 {
            closed = dilate(closed, width: width, height: height, radius: closeRadius)
            closed = erode(closed, width: width, height: height, radius: closeRadius)
        }

        let blurred = gaussianBlur(closed, width: width, height: height, radius: max(1, feather))
        var alpha = [Float](repeating: 0, count: width * height)
        for i in 0..<alpha.count {
            // Map mid-gray band into a soft 0...1 mask with natural edges.
            let v = blurred[i]
            let edge0: Float = 0.12
            let edge1: Float = 0.55
            let t = min(max((v - edge0) / (edge1 - edge0), 0), 1)
            alpha[i] = t * t * (3 - 2 * t)
        }

        let normals = sobelNormals(alpha: alpha, width: width, height: height)
        return SoftMaskResult(alpha: alpha, normals: normals, width: width, height: height)
    }

    // MARK: - Morphology

    private static func dilate(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var dst = src
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for oy in -radius...radius {
                    let yy = min(max(y + oy, 0), height - 1)
                    for ox in -radius...radius {
                        let xx = min(max(x + ox, 0), width - 1)
                        m = max(m, src[yy * width + xx])
                    }
                }
                dst[y * width + x] = m
            }
        }
        return dst
    }

    private static func erode(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var dst = src
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 1
                for oy in -radius...radius {
                    let yy = min(max(y + oy, 0), height - 1)
                    for ox in -radius...radius {
                        let xx = min(max(x + ox, 0), width - 1)
                        m = min(m, src[yy * width + xx])
                    }
                }
                dst[y * width + x] = m
            }
        }
        return dst
    }

    // MARK: - Blur

    private static func gaussianBlur(_ src: [Float], width: Int, height: Int, radius: Float) -> [Float] {
        let sigma = max(radius * 0.5, 0.5)
        let kernelRadius = max(1, Int(ceil(sigma * 2.5)))
        var kernel = [Float](repeating: 0, count: kernelRadius * 2 + 1)
        var sum: Float = 0
        for i in -kernelRadius...kernelRadius {
            let v = exp(-0.5 * Float(i * i) / (sigma * sigma))
            kernel[i + kernelRadius] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        var temp = [Float](repeating: 0, count: src.count)
        var dst = [Float](repeating: 0, count: src.count)

        // Horizontal
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -kernelRadius...kernelRadius {
                    let xx = min(max(x + k, 0), width - 1)
                    acc += src[y * width + xx] * kernel[k + kernelRadius]
                }
                temp[y * width + x] = acc
            }
        }
        // Vertical
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -kernelRadius...kernelRadius {
                    let yy = min(max(y + k, 0), height - 1)
                    acc += temp[yy * width + x] * kernel[k + kernelRadius]
                }
                dst[y * width + x] = acc
            }
        }
        return dst
    }

    // MARK: - Normals

    private static func sobelNormals(alpha: [Float], width: Int, height: Int) -> [SIMD2<Float>] {
        var normals = [SIMD2<Float>](repeating: .zero, count: width * height)
        func sample(_ x: Int, _ y: Int) -> Float {
            alpha[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        for y in 0..<height {
            for x in 0..<width {
                let gx =
                    -sample(x - 1, y - 1) + sample(x + 1, y - 1)
                    - 2 * sample(x - 1, y) + 2 * sample(x + 1, y)
                    - sample(x - 1, y + 1) + sample(x + 1, y + 1)
                let gy =
                    -sample(x - 1, y - 1) - 2 * sample(x, y - 1) - sample(x + 1, y - 1)
                    + sample(x - 1, y + 1) + 2 * sample(x, y + 1) + sample(x + 1, y + 1)
                // Outward normal ≈ gradient of alpha (points toward higher coverage from outside).
                var n = SIMD2<Float>(gx, gy)
                let len = simd_length(n)
                if len > 1e-4 {
                    n /= len
                } else {
                    n = .zero
                }
                normals[y * width + x] = n
            }
        }
        return normals
    }
}

import CoreGraphics
import Foundation
import simd

struct DirtyRect {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { max(0, maxX - minX + 1) }
    var height: Int { max(0, maxY - minY + 1) }

    static func empty() -> DirtyRect {
        DirtyRect(minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
    }

    var isEmpty: Bool { maxX < minX || maxY < minY }

    mutating func union(_ other: DirtyRect) {
        guard !other.isEmpty else { return }
        if isEmpty {
            self = other
            return
        }
        minX = min(minX, other.minX)
        minY = min(minY, other.minY)
        maxX = max(maxX, other.maxX)
        maxY = max(maxY, other.maxY)
    }

    func clamped(width: Int, height: Int) -> DirtyRect {
        guard !isEmpty else { return self }
        return DirtyRect(
            minX: max(0, minX),
            minY: max(0, minY),
            maxX: min(width - 1, maxX),
            maxY: min(height - 1, maxY)
        )
    }
}

/// Float coverage buffer for brush strokes (0...1).
final class MaskBuffer {
    let width: Int
    let height: Int
    private(set) var coverage: [Float]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        coverage = [Float](repeating: 0, count: self.width * self.height)
    }

    func clear() {
        for i in coverage.indices { coverage[i] = 0 }
    }

    /// Soft round brush stamp with smooth falloff. Returns dirty pixel bounds.
    @discardableResult
    func stamp(at point: CGPoint, radius: CGFloat, hardness: CGFloat, erase: Bool) -> DirtyRect {
        let r = max(1, radius)
        let hard = min(max(hardness, 0), 1)
        let minX = max(0, Int(floor(point.x - r - 1)))
        let maxX = min(width - 1, Int(ceil(point.x + r + 1)))
        let minY = max(0, Int(floor(point.y - r - 1)))
        let maxY = min(height - 1, Int(ceil(point.y + r + 1)))
        guard minX <= maxX, minY <= maxY else { return .empty() }

        let inner = r * hard
        let outer = r

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = CGFloat(x) + 0.5 - point.x
                let dy = CGFloat(y) + 0.5 - point.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist <= outer else { continue }
                let t: Float
                if dist <= inner {
                    t = 1
                } else {
                    let u = Float((dist - inner) / max(outer - inner, 0.0001))
                    t = 1 - (u * u * (3 - 2 * u))
                }
                let idx = y * width + x
                if erase {
                    coverage[idx] = max(0, coverage[idx] - t)
                } else {
                    coverage[idx] = min(1, max(coverage[idx], t))
                }
            }
        }
        return DirtyRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Paint a thick stroke between two points.
    @discardableResult
    func stroke(from: CGPoint, to: CGPoint, radius: CGFloat, hardness: CGFloat, erase: Bool) -> DirtyRect {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = hypot(dx, dy)
        let step = max(radius * 0.35, 1)
        let count = max(1, Int(ceil(dist / step)))
        var dirty = DirtyRect.empty()
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let p = CGPoint(x: from.x + dx * t, y: from.y + dy * t)
            dirty.union(stamp(at: p, radius: radius, hardness: hardness, erase: erase))
        }
        return dirty
    }

    /// Sample coverage with bilinear filtering.
    func sample(at point: CGPoint) -> Float {
        let x = point.x
        let y = point.y
        if x < 0 || y < 0 || x >= CGFloat(width - 1) || y >= CGFloat(height - 1) {
            let xi = min(max(Int(x), 0), width - 1)
            let yi = min(max(Int(y), 0), height - 1)
            return coverage[yi * width + xi]
        }
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = Float(x - CGFloat(x0))
        let fy = Float(y - CGFloat(y0))
        let c00 = coverage[y0 * width + x0]
        let c10 = coverage[y0 * width + x0 + 1]
        let c01 = coverage[(y0 + 1) * width + x0]
        let c11 = coverage[(y0 + 1) * width + x0 + 1]
        let c0 = c00 + (c10 - c00) * fx
        let c1 = c01 + (c11 - c01) * fx
        return c0 + (c1 - c0) * fy
    }

    /// Snapshot of coverage at mouse-down for absolute C¹ edge grabs.
    private var grabBaseline: [Float]?
    private var grabOrigin: CGPoint?
    private var grabNormal = SIMD2<Float>(0, -1)
    private var grabDirty = DirtyRect.empty()

    /// Outward unit normal of the coverage field (points from filled -> empty). Nil if flat.
    func edgeNormal(at point: CGPoint) -> SIMD2<Float>? {
        let e: CGFloat = 1.5
        let gx = sample(at: CGPoint(x: point.x + e, y: point.y)) - sample(at: CGPoint(x: point.x - e, y: point.y))
        let gy = sample(at: CGPoint(x: point.x, y: point.y + e)) - sample(at: CGPoint(x: point.x, y: point.y - e))
        var n = SIMD2<Float>(-gx, -gy)
        let len = simd_length(n)
        guard len > 1e-4 else { return nil }
        n /= len
        return n
    }

    /// Local dilate(coverage, radius) - coverage, used as a wide grab band around
    /// the painted boundary (visual outline is a separate thin GPU isocontour).
    /// High near an edge, ~0 deep inside or far outside.
    func boundaryBandValue(at point: CGPoint, radius: CGFloat) -> Float {
        let r = max(1, Int(radius.rounded()))
        let cx = Int(point.x.rounded())
        let cy = Int(point.y.rounded())
        let x0 = max(0, cx - r), x1 = min(width - 1, cx + r)
        let y0 = max(0, cy - r), y1 = min(height - 1, cy + r)
        guard x0 <= x1, y0 <= y1 else { return 0 }
        let r2 = Float(r * r)
        var maxV: Float = 0
        for y in y0...y1 {
            let dy = Float(y - cy)
            let row = y * width
            for x in x0...x1 {
                let dx = Float(x - cx)
                guard dx * dx + dy * dy <= r2 else { continue }
                maxV = max(maxV, coverage[row + x])
            }
        }
        return max(0, maxV - sample(at: point))
    }

    /// Start an Adjust drag: freeze the mask, the grab point, and the local
    /// edge frame (normal/tangent) so each move is an absolute warp from this
    /// snapshot (rest of the curve stays put).
    func beginEdgeGrab(at point: CGPoint) {
        grabBaseline = coverage
        grabOrigin = point
        grabNormal = edgeNormal(at: point) ?? SIMD2<Float>(0, -1)
        grabDirty = .empty()
    }

    func endEdgeGrab() {
        grabBaseline = nil
        grabOrigin = nil
        grabDirty = .empty()
    }

    /// Hermite edge interpolation, built from TWO independent segments that
    /// meet at the drag point. Treat the border locally as a curve y(x):
    /// x = signed distance along the tangent, y = offset along the normal.
    ///   Left segment  x ∈ [-L_left, 0]: Hermite from (−L_left, 0, slope 0)
    ///                                   to (0, 1, slope 0)
    ///   Right segment x ∈ [0, L_right]: Hermite from (0, 1, slope 0)
    ///                                   to (L_right, 0, slope 0)
    /// Each side interpolates independently; they only share the drag point,
    /// where both are flat (slope 0), so the join is C¹ everywhere.
    /// Across the normal the displacement is constant near the edge (a pure
    /// translation of the edge profile — no vertical distortion), fading only
    /// far away to bound the warp.
    @discardableResult
    func warpGrab(to cursor: CGPoint, radius: CGFloat) -> DirtyRect {
        guard let baseline = grabBaseline, let grab = grabOrigin else { return .empty() }

        let dx = Float(cursor.x - grab.x)
        let dy = Float(cursor.y - grab.y)
        let moveLen = hypot(dx, dy)

        let n = grabNormal
        let t = SIMD2<Float>(-n.y, n.x)

        // Fixed tangent windows — do NOT grow with drag distance. Growing them
        // was pulling a wide strip of the boundary outward and splitting the
        // mask into two disconnected blobs on long drags.
        let halfLeft = Float(max(radius * 2.4, 18))
        let halfRight = Float(max(radius * 2.4, 18))
        // Cap displacement so the Hermite slope stays < 1 (no fold / ripple).
        // Short drags: full 1:1 cursor tracking. Very long drags: soft cap.
        let monoCap = min(halfLeft, halfRight) / 1.7
        let dragScale = moveLen > monoCap ? monoCap / moveLen : 1
        let sdx = dx * dragScale
        let sdy = dy * dragScale
        // Small constant margins across the drag axis: the influence hugs the
        // swept region (grab -> cursor) and never reaches deep into the
        // interior or the far side, no matter how far the drag goes.
        let margin = Float(max(radius * 0.7, 8))
        let fadeW = Float(max(radius * 0.8, 8))

        let extent = CGFloat(max(max(halfLeft, halfRight), margin + fadeW)) + 2
        let newROI = DirtyRect(
            minX: max(0, Int(floor(min(grab.x, cursor.x) - extent))),
            minY: max(0, Int(floor(min(grab.y, cursor.y) - extent))),
            maxX: min(width - 1, Int(ceil(max(grab.x, cursor.x) + extent))),
            maxY: min(height - 1, Int(ceil(max(grab.y, cursor.y) + extent)))
        )
        guard !newROI.isEmpty else { return .empty() }

        // Restore anything we touched on previous moves (handles shrinking delta).
        var restore = newROI
        restore.union(grabDirty)
        restore = restore.clamped(width: width, height: height)
        if !restore.isEmpty {
            for y in restore.minY...restore.maxY {
                let row = y * width
                for x in restore.minX...restore.maxX {
                    coverage[row + x] = baseline[row + x]
                }
            }
        }
        guard moveLen > 0.01 else {
            grabDirty = .empty()
            return restore
        }

        let gx = Float(grab.x)
        let gy = Float(grab.y)
        let cx = Float(cursor.x)
        let cy = Float(cursor.y)
        let invHalfLeft = 1 / halfLeft
        let invHalfRight = 1 / halfRight
        let invFadeW = 1 / fadeW
        let invMove = 1 / moveLen
        // Unit drag direction (old edge position -> new edge position).
        let ddx = dx * invMove
        let ddy = dy * invMove

        // Hermite bump: 1 at 0 (flat), 0 with zero slope at 1.
        func bump(_ u: Float) -> Float {
            guard u < 1 else { return 0 }
            let u2 = u * u
            return 1 - u2 * (3 - 2 * u)
        }

        for y in newROI.minY...newROI.maxY {
            for x in newROI.minX...newROI.maxX {
                let px = Float(x) + 0.5
                let py = Float(y) + 0.5

                // Two independent Hermite segments along the tangent,
                // meeting flat at the drag point.
                let oxg = px - gx
                let oyg = py - gy
                let txSigned = oxg * t.x + oyg * t.y
                let w = txSigned < 0
                    ? bump(-txSigned * invHalfLeft)
                    : bump(txSigned * invHalfRight)
                guard w > 0 else { continue }

                // Band along the drag axis, measured from the cursor:
                // full displacement over the swept span [-moveLen-margin, margin],
                // Hermite fade beyond — interior/far side stay untouched.
                let oxc = px - cx
                let oyc = py - cy
                let zeta = oxc * ddx + oyc * ddy
                let v: Float
                if zeta > margin {
                    v = bump((zeta - margin) * invFadeW)
                } else if zeta < -(moveLen + margin) {
                    v = bump((-(moveLen + margin) - zeta) * invFadeW)
                } else {
                    v = 1
                }
                guard v > 0 else { continue }

                let f = w * v
                let sx = px - sdx * f
                let sy = py - sdy * f
                coverage[y * width + x] = sample(baseline, atX: sx, y: sy)
            }
        }

        grabDirty = newROI
        return restore.isEmpty ? newROI : restore
    }

    private func sample(_ buffer: [Float], atX x: Float, y: Float) -> Float {
        if x < 0 || y < 0 || x >= Float(width - 1) || y >= Float(height - 1) {
            let xi = min(max(Int(x.rounded(.down)), 0), width - 1)
            let yi = min(max(Int(y.rounded(.down)), 0), height - 1)
            return buffer[yi * width + xi]
        }
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let c00 = buffer[y0 * width + x0]
        let c10 = buffer[y0 * width + x0 + 1]
        let c01 = buffer[(y0 + 1) * width + x0]
        let c11 = buffer[(y0 + 1) * width + x0 + 1]
        let c0 = c00 + (c10 - c00) * fx
        let c1 = c01 + (c11 - c01) * fx
        return c0 + (c1 - c0) * fy
    }
}

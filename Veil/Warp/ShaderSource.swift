import Foundation

enum ShaderSource {
    /// Metal shaders tuned for Apple GPUs: separable feather + separable image blur.
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct WarpUniforms {
        float amount;
        float blurRadius;
        float showMask;
        float feather;
        float width;
        float height;
        float viewWidth;
        float viewHeight;
        float showBorder;
        float borderCursorX;
        float borderCursorY;
        float borderHover;
        float borderSolidRadius;
    };

    struct FeatherUniforms {
        float feather;
        float width;
        float height;
    };

    struct BlurUniforms {
        float radius;
        float width;
        float height;
    };

    vertex VertexOut veil_vertex(uint vid [[vertex_id]]) {
        float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        float2 uvs[3] = { float2(0, 1), float2(2, 1), float2(0, -1) };
        VertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid];
        return out;
    }

    inline float gaussWeight(float x, float sigma) {
        return exp(-0.5 * x * x / max(sigma * sigma, 1e-4));
    }

    // --- Separable Gaussian feather (coverage -> soft alpha) ---

    kernel void veil_feather_h(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant FeatherUniforms &u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;

        float center = 0.0;
        for (int oy = -1; oy <= 1; ++oy) {
            for (int ox = -1; ox <= 1; ++ox) {
                uint2 p = uint2(
                    clamp(int(gid.x) + ox, 0, int(w) - 1),
                    clamp(int(gid.y) + oy, 0, int(h) - 1)
                );
                center = max(center, src.read(p).r);
            }
        }

        float sigma = max(u.feather * 0.5, 0.5);
        int radius = min(int(ceil(sigma * 2.0)), 16);
        float sum = 0.0;
        float wsum = 0.0;
        for (int i = -radius; i <= radius; ++i) {
            uint x = uint(clamp(int(gid.x) + i, 0, int(w) - 1));
            float sample = (i == 0) ? center : src.read(uint2(x, gid.y)).r;
            float wt = gaussWeight(float(i), sigma);
            sum += sample * wt;
            wsum += wt;
        }
        dst.write(float4(sum / max(wsum, 1e-4)), gid);
    }

    kernel void veil_feather_v(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant FeatherUniforms &u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;

        float sigma = max(u.feather * 0.5, 0.5);
        int radius = min(int(ceil(sigma * 2.0)), 16);
        float sum = 0.0;
        float wsum = 0.0;
        for (int i = -radius; i <= radius; ++i) {
            uint y = uint(clamp(int(gid.y) + i, 0, int(h) - 1));
            float sample = src.read(uint2(gid.x, y)).r;
            float wt = gaussWeight(float(i), sigma);
            sum += sample * wt;
            wsum += wt;
        }
        float v = sum / max(wsum, 1e-4);
        float t = clamp((v - 0.12) / (0.55 - 0.12), 0.0, 1.0);
        float alpha = t * t * (3.0 - 2.0 * t);
        dst.write(float4(alpha), gid);
    }

    // --- Separable Gaussian image blur (true 1px-step convolution) ---
    // Dense taps avoid the H/V striping caused by sparse 7x7 sampling.

    kernel void veil_blur_h(
        texture2d<float, access::sample> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant BlurUniforms &u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;

        constexpr sampler srcSampler(address::clamp_to_edge, filter::linear);
        float sigma = max(u.radius * 0.5, 0.5);
        // Dense kernel: one sample per pixel out to ~2.5σ (capped for laptops).
        int radius = min(max(int(ceil(sigma * 2.5)), 1), 48);
        float4 sum = float4(0.0);
        float wsum = 0.0;
        float invW = 1.0 / float(w);
        float v = (float(gid.y) + 0.5) / float(h);
        for (int i = -radius; i <= radius; ++i) {
            float x = (float(int(gid.x) + i) + 0.5) * invW;
            float wt = gaussWeight(float(i), sigma);
            sum += src.sample(srcSampler, float2(x, v)) * wt;
            wsum += wt;
        }
        dst.write(sum / max(wsum, 1e-4), gid);
    }

    kernel void veil_blur_v(
        texture2d<float, access::read> src [[texture(0)]],
        texture2d<float, access::write> dst [[texture(1)]],
        constant BlurUniforms &u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;

        float sigma = max(u.radius * 0.5, 0.5);
        int radius = min(max(int(ceil(sigma * 2.5)), 1), 48);
        float4 sum = float4(0.0);
        float wsum = 0.0;
        for (int i = -radius; i <= radius; ++i) {
            uint y = uint(clamp(int(gid.y) + i, 0, int(h) - 1));
            float wt = gaussWeight(float(i), sigma);
            sum += src.read(uint2(gid.x, y)) * wt;
            wsum += wt;
        }
        dst.write(sum / max(wsum, 1e-4), gid);
    }

    // --- Composite / warp ---

    inline float sampleAlpha(texture2d<float> soft, sampler s, float2 uv) {
        return soft.sample(s, uv).r;
    }

    fragment float4 veil_warp_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        texture2d<float> softAlpha [[texture(1)]],
        texture2d<float> blurredSource [[texture(2)]],
        texture2d<float> rawCoverage [[texture(3)]],
        constant WarpUniforms &uniforms [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);

        float2 viewUV = in.uv;
        // Vertex UVs already have y=0 at the top of the view — match top-left textures.
        float2 screen = viewUV;

        float imgAspect = uniforms.width / max(uniforms.height, 1.0);
        float viewAspect = uniforms.viewWidth / max(uniforms.viewHeight, 1.0);

        float2 letterboxed;
        if (viewAspect > imgAspect) {
            float w = imgAspect / viewAspect;
            float x0 = (1.0 - w) * 0.5;
            if (screen.x < x0 || screen.x > x0 + w) {
                return float4(0.08, 0.08, 0.1, 1.0);
            }
            letterboxed = float2((screen.x - x0) / w, screen.y);
        } else {
            float h = viewAspect / imgAspect;
            float y0 = (1.0 - h) * 0.5;
            if (screen.y < y0 || screen.y > y0 + h) {
                return float4(0.08, 0.08, 0.1, 1.0);
            }
            letterboxed = float2(screen.x, (screen.y - y0) / h);
        }

        float2 uv = letterboxed;
        float2 texel = float2(1.0 / uniforms.width, 1.0 / uniforms.height);
        float alpha = sampleAlpha(softAlpha, s, uv);

        float a00 = sampleAlpha(softAlpha, s, uv + float2(-texel.x, -texel.y));
        float a10 = sampleAlpha(softAlpha, s, uv + float2(0.0, -texel.y));
        float a20 = sampleAlpha(softAlpha, s, uv + float2(texel.x, -texel.y));
        float a01 = sampleAlpha(softAlpha, s, uv + float2(-texel.x, 0.0));
        float a21 = sampleAlpha(softAlpha, s, uv + float2(texel.x, 0.0));
        float a02 = sampleAlpha(softAlpha, s, uv + float2(-texel.x, texel.y));
        float a12 = sampleAlpha(softAlpha, s, uv + float2(0.0, texel.y));
        float a22 = sampleAlpha(softAlpha, s, uv + float2(texel.x, texel.y));
        float gx = -a00 + a20 - 2.0 * a01 + 2.0 * a21 - a02 + a22;
        float gy = -a00 - 2.0 * a10 - a20 + a02 + 2.0 * a12 + a22;
        float2 grad = float2(gx, gy);
        float2 n = (length(grad) > 1e-4) ? normalize(grad) : float2(0.0);

        float falloff = smoothstep(0.05, 0.55, alpha) * (1.0 - smoothstep(0.75, 1.0, alpha) * 0.35);
        float2 dispPx = n * uniforms.amount * falloff;
        float2 dispUV = float2(dispPx.x / uniforms.width, dispPx.y / uniforms.height);
        float2 sampleUV = uv - dispUV;

        float4 sharp = source.sample(s, sampleUV);
        float4 color = sharp;

        // Mix pre-convolved Gaussian image (no sparse-grid artifacts).
        if (uniforms.blurRadius > 0.5 && alpha > 0.01) {
            float strength = smoothstep(0.02, 0.45, alpha);
            float4 blurred = blurredSource.sample(s, sampleUV);
            color = mix(sharp, blurred, clamp(strength, 0.0, 1.0));
        }

        if (uniforms.showMask > 0.5) {
            float tintAmt = (uniforms.blurRadius > 0.5) ? 0.22 : 0.45;
            float3 tint = float3(0.20, 0.55, 1.0);
            color.rgb = mix(color.rgb, tint, alpha * tintAmt);
        }

        // Border is invisible until the cursor is on the edge. Then: dashed
        // contour, with dash gaps filled solid under the cursor.
        if (uniforms.showBorder > 0.5 && uniforms.borderHover > 0.5) {
            float c00 = rawCoverage.sample(s, uv + float2(-texel.x, -texel.y)).r;
            float c10 = rawCoverage.sample(s, uv + float2(0.0, -texel.y)).r;
            float c20 = rawCoverage.sample(s, uv + float2(texel.x, -texel.y)).r;
            float c01 = rawCoverage.sample(s, uv + float2(-texel.x, 0.0)).r;
            float c11 = rawCoverage.sample(s, uv).r;
            float c21 = rawCoverage.sample(s, uv + float2(texel.x, 0.0)).r;
            float c02 = rawCoverage.sample(s, uv + float2(-texel.x, texel.y)).r;
            float c12 = rawCoverage.sample(s, uv + float2(0.0, texel.y)).r;
            float c22 = rawCoverage.sample(s, uv + float2(texel.x, texel.y)).r;
            float cgx = -c00 + c20 - 2.0 * c01 + 2.0 * c21 - c02 + c22;
            float cgy = -c00 - 2.0 * c10 - c20 + c02 + 2.0 * c12 + c22;
            float2 cgrad = float2(cgx, cgy);
            float gradLen = length(cgrad);
            // Sobel spans ~2 texels; scale so dist is in image pixels.
            float distPx = abs(c11 - 0.5) / max(gradLen * 0.25, 1e-4);
            float line = 1.0 - smoothstep(0.0, 1.35, distPx);
            line *= smoothstep(0.02, 0.12, gradLen);

            float2 px = float2(uv.x * uniforms.width, uv.y * uniforms.height);
            float2 tangent = (gradLen > 1e-4)
                ? normalize(float2(-cgrad.y, cgrad.x))
                : float2(1.0, 0.0);
            float along = dot(px, tangent);
            float dashPeriod = 280.0;
            float dashDuty = 0.62;
            float dash = step(fract(along / dashPeriod + 1e-4), dashDuty);

            float solid = 0.0;
            if (uniforms.borderHover > 0.5) {
                float2 cursor = float2(uniforms.borderCursorX, uniforms.borderCursorY);
                float dCursor = distance(px, cursor);
                float r = max(uniforms.borderSolidRadius, 8.0);
                solid = 1.0 - smoothstep(r * 0.35, r, dCursor);
            }
            line *= max(dash, solid);

            float3 borderTint = float3(1.0, 0.84, 0.1);
            color.rgb = mix(color.rgb, borderTint, clamp(line, 0.0, 1.0));
        }

        return float4(color.rgb, 1.0);
    }
    """
}

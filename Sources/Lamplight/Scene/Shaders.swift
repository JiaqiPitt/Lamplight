import SpriteKit

/// Fragment shaders, written in SpriteKit's GLSL dialect and compiled to Metal at launch.
/// Uniforms are attached from Swift and must not be declared here.
enum Shaders {
    private static let noise = """
    float lhash(vec2 i, float period) {
        i = mod(i, period);
        return fract(sin(dot(i, vec2(12.9898, 78.233))) * 43758.5453);
    }
    float vnoise(vec2 p, float period) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = lhash(i, period);
        float b = lhash(i + vec2(1.0, 0.0), period);
        float c = lhash(i + vec2(0.0, 1.0), period);
        float d = lhash(i + vec2(1.0, 1.0), period);
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    float phash(vec2 p) {
        p = fract(p * vec2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    """

    /// Paper: fibres, soft mottling and slightly darker edges.
    /// `u_org` is the paper-space position of the sprite's bottom-left corner.
    static let paper = noise + """
    void main() {
        vec2 p = u_org + v_tex_coord * u_size;
        vec2 q = p / u_zoom;
        float fib = vnoise(q * vec2(0.5625, 2.625), 256.0) * 0.45
                  + vnoise(q * vec2(2.875, 0.6875) + 31.0, 256.0) * 0.25
                  + vnoise(q * 5.3125 + 9.0, 256.0) * 0.30;
        float cloud = vnoise(q * 0.015625 + 3.0, 64.0) * 0.6 + vnoise(q * 0.0625 + 11.0, 256.0) * 0.4;
        float speck = step(0.9972, lhash(floor(q * 1.25), 1024.0));
        vec3 col = u_tint * (0.915 + 0.060 * fib + 0.040 * cloud) - speck * 0.045;
        float ex = min(p.x - u_edge.x, u_edge.y - p.x) / u_zoom;
        col *= 0.93 + 0.07 * smoothstep(0.0, 16.0, ex);
        float et = (u_top - p.y) / u_zoom;
        col *= 0.94 + 0.06 * smoothstep(0.0, 12.0, et);
        gl_FragColor = vec4(col, 1.0);
    }
    """

    /// The dark enamel behind the paper.
    static let backdrop = noise + """
    void main() {
        vec2 p = v_tex_coord * u_size / u_zoom;
        float n = vnoise(p * 1.9, 1024.0) * 0.6 + vnoise(p * 6.1 + 5.0, 1024.0) * 0.4;
        vec3 col = vec3(0.088, 0.086, 0.084) * (0.80 + 0.40 * n);
        gl_FragColor = vec4(col, 1.0);
    }
    """

    /// The light map, multiplied over everything below it.
    /// A hooded lamp on the carriage throws a cone up the paper; the rest is night.
    static let light = noise + """
    void main() {
        vec2 px = v_tex_coord * u_size;

        vec3 v = vec3(px - u_lamp, -u_h);
        float d2 = dot(v, v);
        float inv = 1.0 / sqrt(d2);
        vec3 vn = v * inv;
        vec3 axis = normalize(vec3(0.0, 1.0, -u_tilt));
        float c = dot(vn, axis);
        float spot = smoothstep(u_cone.x, u_cone.y, c);
        float lambert = u_h * inv;
        float e = u_power * (spot * 0.965 + 0.035) * lambert * (u_h * u_h) / d2;
        float lit = 1.0 - exp(-e);

        vec2 tv = px - u_torch.xy;
        float torch = u_torch.z * exp(-dot(tv, tv) / (u_torch.w * u_torch.w));

        vec2 uv = v_tex_coord - 0.5;
        float vig = 1.0 - dot(uv, uv) * 0.85;

        vec3 warm = vec3(1.0, 0.89, 0.72);
        vec3 candle = vec3(1.0, 0.86, 0.66);
        vec3 night = vec3(0.060, 0.066, 0.085) * u_ambient;
        vec3 room = vec3(0.70, 0.665, 0.60);
        vec3 col = mix(night, room, u_room) * vig + warm * lit + candle * torch;
        col = 1.0 - exp(-col * 1.9);
        col *= 1.0 / (1.0 - exp(-1.9));

        vec2 g = floor(px * u_px);
        float dn = (phash(g + u_t) + phash(g + 37.0 + u_t * 1.7) - 1.0) / 255.0;
        gl_FragColor = vec4(clamp(col + dn * 1.6, 0.0, 1.0), 1.0);
    }
    """
}

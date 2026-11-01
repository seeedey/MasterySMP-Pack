#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

// Vanilla 1.21.11 rendertype_item_entity_translucent_cull.fsh, plus Mastery SMP's marker effects. An item whose
// texel is a marker is not shaded as a picture: this shader draws something in its place. Every other item takes the
// untouched vanilla path at the bottom of main().
//
// The marker is a flat colour no vanilla item texture uses:
//     a = 248   the signature
//     r         10 slash, 11 sigil, 12 beam, 13 sky, 14 rift, 15 cleave, 16 wraith, 17 timer
//     b         the clock: an animated sprite, one frame a tick, 0..255 (12.8 s). The item pass has no time uniform.
//
// Tint parameters, from custom_model_data colors[0]:
//     slash    r life 0..1    g gold 0..1 (azure at 0)   b intensity
//     sigil    r progress     g contested                b pulse
//     beam     r strength     g contested                b flash
//     sky      r presence     g tension                  b flash
//     rift     r life 0..1    g reach 0..1               b heat
//     cleave   r life 0..1    g crimson 0..1 (ember at 0) b intensity
//     wraith   r presence     g voice                    b flash
//     timer    r minutes      g seconds                  b flash     (r and g each hold 4n + 2, so a rounding slip is harmless)

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec2 texCoord0;
in vec2 texCoord1;

in vec3 fxPos;
in vec2 fxLocal;
flat in vec4 fxTint;
flat in vec4 fxProjZW;

out vec4 fragColor;

#define TAU 6.28318530718
// A zero the compiler cannot prove is zero: as a loop bound it stops the driver unrolling noise loops (compile time).
#define DYN0 (int(gl_FragCoord.x) >> 24)

const vec3 AZURE = vec3(0.30, 0.72, 1.0);
const vec3 GOLD = vec3(1.0, 0.72, 0.16);
const vec3 CRIMSON = vec3(1.0, 0.16, 0.14);

// ---- hashes and noise (after Dave Hoskins; the Core shaders noise kit) ------------------------------------------

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// an offset that comes back to its start as the clock goes once round, so animated noise loops with no jump
vec3 loop3(float ph, float r) {
    float a = ph * TAU;
    return vec3(cos(a), sin(a), 0.0) * r;
}

vec4 h4(vec4 x, vec4 y, float z) {
    vec4 a = fract(x * 0.1031);
    vec4 b = fract(y * 0.1031);
    float c = fract(z * 0.1031);
    vec4 d = a * (c + 31.32) + b * (b + 31.32) + c * (a + 31.32);
    a += d;
    b += d;
    return fract((a + b) * (vec4(c) + d));
}

float vnoise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec4 xs = i.x + vec4(0.0, 1.0, 0.0, 1.0);
    vec4 ys = i.y + vec4(0.0, 0.0, 1.0, 1.0);
    vec4 hz = mix(h4(xs, ys, i.z), h4(xs, ys, i.z + 1.0), u.z);
    vec2 hy = mix(hz.xz, hz.yw, u.x);
    return mix(hy.x, hy.y, u.y);
}

float fbm4(vec3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4 + DYN0; i++) {
        s += a * vnoise3(p);
        p = p * 2.03 + vec3(1.7, 9.2, 4.1);
        a *= 0.5;
    }
    return s / 0.9375;
}

// ---- the slash ---------------------------------------------------------------------------------------------------
// A thin crescent cut from two circles, so both tips come to a true point. Its outer edge is the blade's path and burns
// white; behind it the light thins into a trail. The plugin turns the display through the swing, which the client
// interpolates at frame rate; the shader only has to burn the crescent away as it dies.

vec4 slash(vec2 p, float ph, vec3 k) {
    float life = k.r, gold = k.g, power = k.b;
    float r = length(p);
    float depth = 0.90 - r;                                 // distance in from the leading edge
    float inner = 0.80 - length(p - vec2(-0.13, 0.0));      // > 0 inside the second circle, which cuts the crescent
    float body = 1.0 - smoothstep(-0.01, 0.015, max(-depth, inner));

    // long grain along the arc, so the trail reads as speed and not as a flat fill
    float arc = atan(p.y, p.x);
    float grain = vnoise3(vec3(arc * 2.2, depth * 34.0, 1.0) + loop3(ph, 0.4));
    float wisp = fbm4(vec3(p * 5.5, 0.0) + loop3(ph, 0.5));
    float dissolve = smoothstep(life * 1.3 - 0.16, life * 1.3 + 0.03, wisp + 0.16 + 0.22 * smoothstep(0.0, 0.2, depth));

    float edge = exp(-max(depth, 0.0) * 42.0);
    float trail = exp(-max(depth, 0.0) * 6.0) * (0.55 + 0.75 * grain);
    float bloom = exp(-abs(depth) * 11.0) * (1.0 - smoothstep(0.0, 1.0, inner * 12.0)) * smoothstep(-0.3, 0.45, p.x);

    vec3 tint = mix(AZURE, GOLD, gold);
    vec3 col = mix(tint * 0.8, vec3(1.0, 0.99, 0.95), edge);
    col = mix(col, tint, (1.0 - edge) * 0.5);
    float a = (body * (edge + trail * 0.82) + bloom * 0.22) * dissolve * (0.45 + 0.55 * power);
    a *= 1.0 - smoothstep(0.88, 1.0, max(abs(p.x), abs(p.y)));
    return vec4(col, clamp(a, 0.0, 0.96));
}

// ---- the sigil ---------------------------------------------------------------------------------------------------
// The capture circle round the sword: rings and a turning band of glyphs, with the leader's progress lit round the
// rim. It lies flat on the ground and keeps its own depth so that hills and feet still cover it.

float ring(float r, float at, float w, float px) {
    return 1.0 - smoothstep(w, w + px * 1.5, abs(r - at));
}

float glyphs(float angle, float r, float inner, float outer, float count, float seed, float px) {
    float v = (r - inner) / (outer - inner);
    if (v < 0.0 || v > 1.0) return 0.0;
    float u = fract(angle) * count;
    float cell = floor(u);
    vec2 g = vec2(fract(u) * 3.0, v * 4.0);
    vec2 c = floor(g);
    float on = step(0.46, hash21(c + vec2(mod(cell, count) * 3.17 + seed, seed)));
    vec2 e = abs(fract(g) - 0.5);
    float mark = 1.0 - smoothstep(0.34, 0.34 + px * 12.0, max(e.x, e.y));
    return on * mark * step(0.11, fract(u)) * step(fract(u), 0.89);
}

vec4 sigil(vec2 p, float px, float ph, vec3 k) {
    float progress = k.r, contested = k.g, pulse = k.b;
    float r = length(p);
    float angle = atan(p.y, p.x) / TAU + 0.5;

    float lines = ring(r, 0.93, 0.006, px) + ring(r, 0.73, 0.005, px) * 0.8 + ring(r, 0.42, 0.005, px) * 0.8;
    lines += glyphs(angle + ph, r, 0.76, 0.90, 36.0, 3.0, px) * 0.85;
    lines += glyphs(angle - ph * 2.0, r, 0.45, 0.55, 18.0, 11.0, px) * 0.6;

    // two turning squares, an eight-point star between the rings
    for (int i = 0; i < 2 + DYN0; i++) {
        float a = TAU * (ph * (i == 0 ? 1.0 : -1.0) + float(i) * 0.125);
        vec2 q = mat2(cos(a), -sin(a), sin(a), cos(a)) * p;
        float box = max(abs(q.x), abs(q.y));
        lines += (1.0 - smoothstep(0.004, 0.004 + px * 1.5, abs(box - 0.50))) * step(r, 0.73) * 0.55;
    }

    // the rim fills as the leader holds the hill; the leading edge burns brightest
    float along = fract(angle + 0.25);
    float filled = step(along, progress) * step(0.01, progress);
    float rim = (1.0 - smoothstep(0.018, 0.018 + px * 2.0, abs(r - 0.965))) * filled;
    float head = exp(-abs(along - progress) * 60.0) * filled * (1.0 - smoothstep(0.0, 0.05, abs(r - 0.965)));

    float pool = exp(-r * r * 5.0) * 0.20;
    float breath = 0.75 + 0.25 * sin(ph * TAU * 3.0);
    vec3 col = mix(AZURE, GOLD, smoothstep(0.0, 1.0, progress));
    col = mix(col, CRIMSON, contested);

    vec3 c = col * (lines + pool) + vec3(1.0, 0.92, 0.70) * (rim + head);
    float a = clamp((lines * breath + pool + rim + head) * (0.8 + 0.8 * pulse), 0.0, 0.95);
    a *= 1.0 - smoothstep(0.97, 1.0, r);
    return vec4(mix(c / max(lines + pool + rim + head, 0.001), vec3(1.0), pulse * 0.5), a);
}

// ---- the beam ----------------------------------------------------------------------------------------------------
// A pillar of light standing on the sword. Two noise layers scroll up half a cycle apart and crossfade, the usual way
// to get endless motion from a single-byte clock. Motes are soft points in cells that scroll a whole number of rows a
// loop, with the row hashed modulo that number, so the loop closes.

float rising(vec2 p, float t) {
    float f = fract(t);
    float a = vnoise3(vec3(p.x, p.y - f * 3.0, 2.0));
    float b = vnoise3(vec3(p.x + 7.0, p.y - fract(t + 0.5) * 3.0, 5.0));
    return mix(a, b, abs(2.0 * f - 1.0));
}

float motes(vec2 l, float ph) {
    const float ROWS = 24.0;
    vec2 g = vec2(l.x * 70.0, l.y * 90.0 - ph * ROWS);
    vec2 cell = floor(g);
    vec2 h = vec2(hash21(vec2(cell.x, mod(cell.y, ROWS))), hash21(vec2(mod(cell.y, ROWS), cell.x + 9.0)));
    if (h.x > 0.20) return 0.0;
    float d = length(fract(g) - (0.3 + 0.4 * h.yx));
    return exp(-d * d * 42.0) * (0.5 + 0.5 * sin(ph * TAU * 3.0 + h.y * TAU));
}

vec4 beam(vec2 l, float ph, vec3 k) {
    float strength = k.r, contested = k.g, flash = k.b;
    float x = l.x * 2.0 - 1.0;
    float y = l.y;
    float width = 0.016 + 0.003 * sin(ph * TAU * 2.0) + 0.02 * flash;
    float wob = (rising(vec2(3.0, y * 6.0), ph * 2.0) - 0.5) * 0.012;
    float core = exp(-(x + wob) * (x + wob) / (width * width * 0.5));
    float inner = exp(-abs(x + wob) / (width * 2.4));
    float sheath = exp(-abs(x) / 0.10);
    float shimmer = rising(vec2(x * 7.0, y * 9.0), ph * 2.0);
    float spark = motes(l, ph) * exp(-abs(x) / 0.13);

    float fade = smoothstep(0.0, 0.012, y) * pow(1.0 - y, 1.4);
    float a = (core + inner * 0.55 + sheath * (0.22 + 0.42 * shimmer)) * fade + spark * 0.95 * smoothstep(0.0, 0.03, y) * (1.0 - y);
    a *= (0.25 + 0.75 * strength) * (1.0 + flash);
    a *= 1.0 - smoothstep(0.8, 1.0, abs(x));

    vec3 tint = mix(mix(AZURE, GOLD, 0.25 + 0.75 * y), CRIMSON, contested);
    return vec4(mix(tint, vec3(1.0, 0.98, 0.92), clamp(core + inner * 0.25, 0.0, 1.0)), clamp(a, 0.0, 0.92));
}

// ---- the sky -----------------------------------------------------------------------------------------------------
// Golden hour over the peak: a warm low sun and a towering cloud deck lit from beneath. Density is sampled along the
// eye ray through a thin slab rather than on one plane, which is what gives the clouds their billowed, stacked look,
// and each sample is lit by how much cloud sits between it and the sun. Tension drags the whole sky toward a bruised
// red storm as the hill nears its end.

const vec3 SUN = normalize(vec3(-0.78, 0.13, -0.61));

float cloudAt(vec3 p, float ph, float cover) {
    vec3 q = p + loop3(ph, 0.10);
    float warp = fbm4(q * 0.55 + vec3(3.0, 1.0, 8.0));
    float n = fbm4(q + vec3(warp * 1.1, 0.0, warp * 0.7));
    float billow = 1.0 - abs(2.0 * vnoise3(q * 4.3 + vec3(warp)) - 1.0);
    return smoothstep(cover, cover + 0.30, n + billow * 0.09);
}

vec4 sky(vec3 d, float ph, vec3 k) {
    float presence = k.r, tension = k.g, flash = k.b;
    float up = d.y;
    float sunDot = max(dot(d, SUN), 0.0);
    float sunGlow = pow(sunDot, 7.0);

    vec3 zenith = mix(vec3(0.10, 0.22, 0.46), vec3(0.11, 0.05, 0.17), tension);
    vec3 mid = mix(vec3(0.50, 0.52, 0.66), vec3(0.42, 0.14, 0.22), tension);
    vec3 horizon = mix(vec3(1.0, 0.66, 0.38), vec3(0.95, 0.28, 0.12), tension);
    vec3 col = mix(horizon, mid, smoothstep(0.0, 0.22, up));
    col = mix(col, zenith, smoothstep(0.14, 0.70, up));
    col += vec3(1.0, 0.60, 0.26) * sunGlow * 0.5;
    col = mix(col, vec3(1.0, 0.97, 0.84), smoothstep(0.9986, 0.9993, sunDot));

    // march a slab of cloud overhead, front to back. Past the horizon the ray never enters it.
    float cover = 0.44 - 0.10 * tension;
    float clear = 1.0;
    vec3 cloud = vec3(0.0);
    if (up > -0.02) {
        float deck = max(up + 0.10, 0.06);
        vec3 ray = vec3(d.x, 0.0, d.z) / deck;
        vec3 shadow = mix(vec3(0.30, 0.29, 0.45), vec3(0.16, 0.07, 0.14), tension);
        vec3 bright = mix(vec3(1.0, 0.78, 0.55), vec3(1.0, 0.44, 0.22), tension);
        for (int i = 0; i < 3 + DYN0; i++) {
            float t = 1.0 + float(i) * 0.11;
            vec3 p = ray * t * 1.1 + vec3(0.0, 0.0, float(i) * 0.37);
            float c = cloudAt(p, ph, cover);
            float toSun = cloudAt(p + vec3(SUN.x, 0.0, SUN.z) * 0.22, ph, cover);
            float lit = clamp(0.62 + (c - toSun) * 1.5, 0.0, 1.0);
            vec3 tone = mix(shadow, bright, lit * lit);
            tone += vec3(1.0, 0.68, 0.36) * pow(sunDot, 18.0) * (1.0 - c) * 0.9;     // the thin edges catch the sun
            float alpha = c * 0.55;
            cloud += tone * alpha * clear;
            clear *= 1.0 - alpha;
        }
        float reach = smoothstep(-0.02, 0.05, up);
        col = mix(col, cloud + col * clear, reach);
    }

    // shafts: noise on the direction around the sun, never atan, which would leave a seam. Only breaks of cloud let
    // them through, and they die fast away from the sun.
    vec3 around = normalize(d - SUN * dot(d, SUN) + vec3(1e-4));
    float shafts = vnoise3(around * 6.0 + loop3(ph, 0.15));
    col += vec3(1.0, 0.72, 0.40) * shafts * shafts * pow(sunDot, 12.0) * (0.25 + 0.5 * clear) * smoothstep(-0.02, 0.08, up);

    col = mix(mix(FogColor.rgb, col, 0.4), col, smoothstep(-0.03, 0.10, up));   // meet the terrain's distance fog
    col = mix(col, vec3(1.0, 0.94, 0.78), flash * 0.8);
    return vec4(col, presence);
}

// ---- the rift ----------------------------------------------------------------------------------------------------
// The ground splitting under an axe: a net of cracks, flung out from the middle, with molten light in them. Cells come
// from a voronoi pattern warped round the centre, so the cracks run outward rather than sitting in a honeycomb.

vec2 cellEdge(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 c = vec2(float(x), float(y));
            vec2 h = vec2(hash21(i + c), hash21(i + c + 17.0));
            float d = length(c + h - f);
            if (d < f1) {
                f2 = f1;
                f1 = d;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }
    return vec2(f2 - f1, f1);
}

vec4 rift(vec2 p, float px, float ph, vec3 k) {
    float life = k.r, reach = k.g, heat = k.b;
    float r = length(p);
    float angle = atan(p.y, p.x);
    vec2 a = vec2(cos(angle), sin(angle));

    // long cells along the radius: the first coordinate moves slowly outward, the second goes round
    float wob = fbm4(vec3(a * 1.6, r * 2.0) + vec3(4.0, 1.0, 2.0)) - 0.5;
    vec2 q = vec2(a.x, a.y) * (3.0 + 1.6 * wob) + a.yx * vec2(-1.0, 1.0) * sqrt(r) * 4.0 + a * r * 1.5;
    float e = cellEdge(q).x;
    float width = 0.05 + 0.13 * (1.0 - smoothstep(0.0, 0.9, r));
    float crack = 1.0 - smoothstep(width * 0.35, width, e);
    float core = 1.0 - smoothstep(0.0, width * 0.4, e);

    float mouth = 0.28 + 0.72 * reach;
    float fall = 1.0 - smoothstep(mouth * 0.55, mouth, r);
    float pool = exp(-r * r * 9.0 / max(mouth, 0.2)) * 0.55;

    float flow = vnoise3(vec3(q * 1.4, 0.0) + loop3(ph, 0.8));
    float burn = fbm4(vec3(p * 3.4, 3.0) + loop3(ph, 0.25));
    float dissolve = smoothstep(life * 1.15 - 0.15, life * 1.15 + 0.05, burn + 0.18);

    float glow = (crack * (0.6 + 0.6 * flow) * fall + pool) * dissolve;
    vec3 col = mix(vec3(0.62, 0.05, 0.05), vec3(1.0, 0.36, 0.08), clamp(glow * 1.4, 0.0, 1.0));
    col = mix(col, vec3(1.0, 0.86, 0.48), clamp(core * fall * dissolve * (0.3 + heat), 0.0, 1.0));
    float a2 = clamp(glow * (0.55 + 0.7 * heat), 0.0, 0.95);
    a2 *= 1.0 - smoothstep(0.92, 1.0, r);
    return vec4(col, a2);
}

// ---- the cleave --------------------------------------------------------------------------------------------------
// The slash's heavy cousin: a thick wedge with a torn trailing edge. Where the sword leaves a clean line of light, the
// axe leaves a wound in the air with embers coming off it.

vec4 cleave(vec2 p, float ph, vec3 k) {
    float life = k.r, crimson = k.g, power = k.b;
    float r = length(p);
    float arc = atan(p.y, p.x);
    float depth = 0.92 - r;

    float tear = fbm4(vec3(arc * 3.2, r * 2.0, 4.0) + loop3(ph, 0.3));
    float inner = 0.84 - length(p - vec2(-0.12 - 0.20 * tear, 0.0));
    float body = 1.0 - smoothstep(-0.015, 0.02, max(-depth, inner));

    float grain = vnoise3(vec3(arc * 3.0, depth * 26.0, 7.0) + loop3(ph, 0.4));
    float burn = fbm4(vec3(p * 5.0, 2.0) + loop3(ph, 0.5));
    float dissolve = smoothstep(life * 1.3 - 0.18, life * 1.3 + 0.04, burn + 0.14 + 0.25 * smoothstep(0.0, 0.25, depth));

    float edge = exp(-max(depth, 0.0) * 30.0);
    float meat = exp(-max(depth, 0.0) * 3.6) * (0.5 + 0.8 * grain);

    // sparks thrown off the edge: soft points in polar cells
    vec2 g = vec2(arc * 9.0, r * 16.0 + ph * 16.0);
    vec2 cell = floor(g);
    float seed = hash21(vec2(cell.x, mod(cell.y, 16.0)));
    float spark = step(0.86, seed) * exp(-dot(fract(g) - 0.5, fract(g) - 0.5) * 30.0) * smoothstep(0.55, 0.85, r) * smoothstep(1.0, 0.86, r);

    vec3 hot = vec3(1.0, 0.93, 0.70);
    vec3 tint = mix(vec3(1.0, 0.42, 0.08), vec3(0.95, 0.07, 0.06), crimson);
    vec3 col = mix(tint, hot, edge);
    float a = (body * (edge + meat) + spark * 1.2) * dissolve * (0.45 + 0.55 * power);
    a *= 1.0 - smoothstep(0.90, 1.0, max(abs(p.x), abs(p.y)));
    return vec4(col, clamp(a, 0.0, 0.96));
}

// ---- the wraith --------------------------------------------------------------------------------------------------
// The black figure at Rampage, ray-marched as a real solid inside its quad: a cowl with a hollow in it, shoulders, hanging
// sleeves and a pleated robe that frays to smoke. The quad only gives it a place to draw. The figure keeps facing the
// viewer but sways, and its light is fixed to the world, so its shading changes as you walk round it. Units: 1 = half the
// quad, y up, +z toward the viewer.

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float smax(float a, float b, float k) {
    return -smin(-a, -b, k);
}

float capsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a;
    vec3 ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)) - r;
}

mat2 turn(float a) {
    return mat2(cos(a), -sin(a), sin(a), cos(a));
}

float swayBody(float ph) {
    return 0.26 * sin(ph * TAU);
}

float swayHead(float ph) {
    return 0.34 * sin(ph * TAU + 1.7);
}

const vec3 HEAD = vec3(0.0, 0.45, 0.02);

float wraithMap(vec3 p, float ph, float erode) {
    vec3 q = p;
    q.xz = turn(swayBody(ph)) * q.xz;
    float low = smoothstep(0.2, -0.7, q.y);
    q.xz += low * 0.05 * vec2(sin(q.y * 7.0 + ph * TAU), cos(q.y * 6.0 - ph * TAU * 2.0));

    vec3 h = q - HEAD;
    h.xz = turn(swayHead(ph)) * h.xz;
    float hood = length(h * vec3(1.0, 0.86, 0.94)) - 0.15;
    hood = smin(hood, capsule(h, vec3(0.0, 0.05, -0.05), vec3(0.0, 0.215, -0.10), 0.05), 0.12);
    hood = smax(hood, 0.102 - length(h - vec3(0.0, -0.03, 0.125)), 0.018);     // the hollow the eyes sit in

    float shoulders = capsule(q * vec3(1.0, 1.0, 1.35), vec3(-0.21, 0.25, 0.0), vec3(0.21, 0.25, 0.0), 0.10);

    float along = atan(q.z, q.x);
    float pleat = sin(along * 9.0 + q.y * 2.4 + 2.0 * sin(q.y * 3.0)) * (0.010 + 0.030 * low);
    float radius = 0.18 + 0.23 * clamp(0.30 - q.y, 0.0, 1.2);
    float robe = length(q.xz * vec2(1.0, 1.22)) - radius - pleat;
    robe = smax(robe, q.y - 0.30, 0.06);
    robe = smax(robe, -0.78 - q.y, 0.08);

    vec3 m = vec3(abs(q.x), q.y, q.z);
    float sleeve = capsule(m, vec3(0.25, 0.24, 0.01), vec3(0.37, -0.22, 0.09), 0.065 + 0.075 * clamp(0.25 - q.y, 0.0, 0.5));

    float d = smin(hood, shoulders, 0.09);
    d = smin(d, robe, 0.07);
    d = smin(d, sleeve, 0.05);
    return d + (vnoise3(q * 6.0 + loop3(ph, 0.4)) - 0.5) * (0.02 + 0.20 * low * low) + erode;
}

vec3 wraithNormal(vec3 p, float ph, float erode) {
    const vec2 e = vec2(0.008, -0.008);
    return normalize(e.xyy * wraithMap(p + e.xyy, ph, erode) + e.yyx * wraithMap(p + e.yyx, ph, erode)
            + e.yxy * wraithMap(p + e.yxy, ph, erode) + e.xxx * wraithMap(p + e.xxx, ph, erode));
}

// The eyes are lights hanging inside the cowl. Each is a thin slit, slanted, and hidden unless the ray clears the hood.
float wraithEye(vec3 ro, vec3 rd, float hit, float side, float ph) {
    vec3 at = vec3(0.040 * side, -0.025, 0.075);
    at.xz = at.xz * turn(swayHead(ph));
    at += HEAD;
    at.xz = at.xz * turn(swayBody(ph));
    float t = dot(at - ro, rd);
    if (t > hit + 0.03) return 0.0;
    vec3 off = ro + rd * t - at;
    float slant = off.y + off.x * side * 0.45;
    return exp(-(off.x * off.x * 1800.0 + slant * slant * 22000.0)) + exp(-dot(off, off) * 1500.0) * 0.22;
}

// `P` is this fragment on the quad, `U` and `V` the quad's edges, `l` where it is across them.
vec4 wraith(vec3 P, vec3 U, vec3 V, vec2 l, float ph, vec3 k, out vec3 surface) {
    float presence = k.r, voice = k.g, flash = k.b;
    vec3 C = P - U * (l.x - 0.5) - V * (l.y - 0.5);
    float H = length(V) * 0.5;
    vec3 Y = vec3(0.0, 1.0, 0.0);
    vec3 Z = normalize(vec3(-C.x, 0.0, -C.z));
    vec3 X = cross(Y, Z);

    vec3 eye = normalize(P);
    vec3 ro = vec3(dot(-C, X), dot(-C, Y), dot(-C, Z)) / H;
    vec3 rd = vec3(dot(eye, X), dot(eye, Y), dot(eye, Z));
    surface = P + eye * H * 0.6;

    float erode = (1.0 - presence) * 0.10;
    float t = max(0.0, length(ro) - 1.15);
    float end = length(ro) + 1.4;
    float nearest = 8.0;
    float hit = -1.0;
    for (int i = 0; i < 56 + DYN0; i++) {
        float d = wraithMap(ro + rd * t, ph, erode);
        nearest = min(nearest, d);
        if (d < 0.0025) {
            hit = t;
            break;
        }
        t += d * 0.82;
        if (t > end) break;
    }

    float eyes = (wraithEye(ro, rd, hit < 0.0 ? end : hit, 1.0, ph) + wraithEye(ro, rd, hit < 0.0 ? end : hit, -1.0, ph))
            * presence * (0.8 + 0.5 * voice + 0.12 * sin(ph * TAU * 2.0));
    vec3 eyeCol = mix(vec3(1.0, 0.13, 0.06), vec3(1.0, 0.85, 0.58), clamp(eyes * voice * 0.8, 0.0, 1.0));

    if (hit < 0.0) {
        float smoke = exp(-max(nearest, 0.0) * 13.0) * 0.5 * smoothstep(0.25, 0.75, fbm4(vec3((ro + rd * length(ro)).xy * 3.0, 2.0) + loop3(ph, 0.55)));
        float a = smoke * presence;
        a *= 1.0 - smoothstep(0.88, 1.0, max(abs(l.x * 2.0 - 1.0), abs(l.y * 2.0 - 1.0)));
        vec3 col = mix(vec3(0.03, 0.012, 0.02), eyeCol, clamp(eyes, 0.0, 1.0));
        return vec4(col, clamp(max(a, eyes), 0.0, 0.95));
    }

    vec3 p = ro + rd * hit;
    surface = C + (X * p.x + Y * p.y + Z * p.z) * H;
    vec3 n = wraithNormal(p, ph, erode);
    float shade = clamp(wraithMap(p + n * 0.05, ph, erode) / 0.05, 0.0, 1.0);    // folds and the inside of the cowl go dark

    vec3 sun = normalize(vec3(-0.5, 0.75, 0.42));
    vec3 lamp = vec3(dot(sun, X), dot(sun, Y), dot(sun, Z));
    float lit = max(dot(n, lamp), 0.0);
    float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
    float under = max(-n.y, 0.0);

    vec3 col = vec3(0.016, 0.014, 0.022);
    col += vec3(0.13, 0.135, 0.17) * lit * lit * shade;
    col += vec3(0.022, 0.026, 0.04) * (0.5 + 0.5 * n.y) * shade;
    col += vec3(0.42, 0.035, 0.03) * under * under * (0.5 + 0.5 * flash);
    col += vec3(0.70, 0.05, 0.04) * rim * shade * (0.55 + 0.9 * flash);
    col = mix(col, eyeCol, clamp(eyes, 0.0, 1.0));

    float a = presence * smoothstep(-0.86, -0.56, p.y + (fbm4(vec3(p.xz * 5.0, 1.0) + loop3(ph, 0.5)) - 0.5) * 0.4);
    return vec4(col, clamp(max(a, eyes), 0.0, 0.99));
}

// ---- the timer ---------------------------------------------------------------------------------------------------
// MM:SS in tall segments, burning. A segment is a bevelled bar; each digit is a seven bit mask of them.

float segment(vec2 p, vec2 a, vec2 b, float w) {
    vec2 ba = b - a;
    float t = clamp(dot(p - a, ba) / dot(ba, ba), 0.0, 1.0);
    vec2 n = abs(p - a - ba * t);
    return n.x + n.y - w;       // a diamond section, so the bars end in points
}

float digit(vec2 p, int n) {
    const float W = 0.30, H = 0.50, G = 0.055;
    int bits = n == 0 ? 63 : n == 1 ? 6 : n == 2 ? 91 : n == 3 ? 79 : n == 4 ? 102 : n == 5 ? 109 : n == 6 ? 125 : n == 7 ? 7 : n == 8 ? 127 : 111;
    float d = 1.0;
    if ((bits & 1) != 0) d = min(d, segment(p, vec2(-W + G, H), vec2(W - G, H), 0.075));
    if ((bits & 2) != 0) d = min(d, segment(p, vec2(W, H - G), vec2(W, G), 0.075));
    if ((bits & 4) != 0) d = min(d, segment(p, vec2(W, -G), vec2(W, -H + G), 0.075));
    if ((bits & 8) != 0) d = min(d, segment(p, vec2(-W + G, -H), vec2(W - G, -H), 0.075));
    if ((bits & 16) != 0) d = min(d, segment(p, vec2(-W, -G), vec2(-W, -H + G), 0.075));
    if ((bits & 32) != 0) d = min(d, segment(p, vec2(-W, H - G), vec2(-W, G), 0.075));
    if ((bits & 64) != 0) d = min(d, segment(p, vec2(-W + G, 0.0), vec2(W - G, 0.0), 0.075));
    return d;
}

vec4 timer(vec2 p, float px, float ph, vec3 k) {
    int minutes = int(k.r * 255.0 + 0.5) / 4;
    int seconds = int(k.g * 255.0 + 0.5) / 4;
    float flash = k.b;

    // five cells across the quad's width. Height comes from the same scale, so the middle band of the quad holds it all
    vec2 q = p * 2.75;
    float d = 1.0;
    d = min(d, digit(q - vec2(-2.05, 0.0), minutes / 10));
    d = min(d, digit(q - vec2(-1.05, 0.0), minutes % 10));
    d = min(d, digit(q - vec2(1.05, 0.0), seconds / 10));
    d = min(d, digit(q - vec2(2.05, 0.0), seconds % 10));
    float blink = 0.55 + 0.45 * step(fract(ph * 6.4), 0.5);
    d = min(d, length(q - vec2(0.0, 0.22)) - 0.075 * blink);
    d = min(d, length(q - vec2(0.0, -0.22)) - 0.075 * blink);

    float fuzz = px * 2.75;
    float solid = 1.0 - smoothstep(-fuzz, fuzz, d);
    float inner = 1.0 - smoothstep(-0.05, 0.0, d + 0.035);
    float halo = exp(-max(d, 0.0) * 5.5) * 0.55 + exp(-max(d, 0.0) * 22.0) * 0.5;
    float heat = fbm4(vec3(q * vec2(1.5, 2.6) - vec2(0.0, 0.0), 6.0) + loop3(ph, 0.5));

    vec3 hot = mix(vec3(1.0, 0.16, 0.08), vec3(1.0, 0.70, 0.30), smoothstep(0.42, 0.72, heat));
    vec3 col = mix(vec3(0.85, 0.03, 0.04), hot, solid);
    col = mix(col, vec3(1.0, 0.93, 0.74), inner * (0.25 + 0.75 * flash));
    float a = max(solid, halo * (0.7 + 0.3 * heat) * (1.0 + flash));
    a *= 1.0 - smoothstep(0.85, 1.0, max(abs(p.x), abs(p.y)));
    a *= 1.0 - smoothstep(0.35, 0.62, abs(p.y));
    return vec4(col, clamp(a, 0.0, 0.97));
}

// ---- depth -------------------------------------------------------------------------------------------------------

float depthAt(vec3 p) {
    float z = (ModelViewMat * vec4(p, 1.0)).z;
    return 0.5 + 0.5 * (fxProjZW.x * z + fxProjZW.y) / (fxProjZW.z * z + fxProjZW.w);
}

// ---- entry -------------------------------------------------------------------------------------------------------

void main() {
    vec4 texel = texture(Sampler0, texCoord0);

    // derivatives have to be taken in uniform control flow, so before any branch
    float px = length(vec2(dFdx(fxLocal.x), dFdy(fxLocal.x))) * 2.0;
    vec3 dPx = dFdx(fxPos);
    vec3 dPy = dFdy(fxPos);
    vec2 dLx = dFdx(fxLocal);
    vec2 dLy = dFdy(fxLocal);
    float det = dLx.x * dLy.y - dLx.y * dLy.x;
    vec3 edgeU = (dPx * dLy.y - dPy * dLx.y) / det;
    vec3 edgeV = (dPy * dLx.x - dPx * dLy.x) / det;

    vec4 m = texel * 255.0;
    if (abs(m.a - 248.0) < 0.5 && m.r > 9.5 && m.r < 17.5) {
        float ph = floor(m.b + 0.5) / 256.0;
        vec3 k = fxTint.rgb;
        vec2 p = fxLocal * 2.0 - 1.0;
        vec4 col;
        if (m.r > 12.5 && m.r < 13.5) {
            gl_FragDepth = gl_FragCoord.z;
            fragColor = sky(normalize(fxPos), ph, k);
            return;
        }
        if (m.r > 16.5) {
            col = timer(p, px, ph, k);
            gl_FragDepth = depthAt(fxPos + normalize(fxPos) * 1.0);
        } else if (m.r > 15.5) {
            vec3 surface;
            col = wraith(fxPos, edgeU, edgeV, fxLocal, ph, k, surface);
            gl_FragDepth = depthAt(surface);
        } else if (m.r > 14.5) {
            col = cleave(p, ph, k);
            gl_FragDepth = depthAt(fxPos + normalize(fxPos) * 0.3);
        } else if (m.r > 13.5) {
            col = rift(p, px, ph, k);
            gl_FragDepth = gl_FragCoord.z;
        } else if (m.r > 11.5) {
            col = beam(fxLocal, ph, k);
            gl_FragDepth = depthAt(fxPos + normalize(fxPos) * 2.0);     // whatever moves inside the light stays in front
        } else if (m.r > 10.5) {
            col = sigil(p, px, ph, k);
            gl_FragDepth = gl_FragCoord.z;
        } else {
            col = slash(p, ph, k);
            gl_FragDepth = depthAt(fxPos + normalize(fxPos) * 0.3);
        }
        if (col.a < 0.02) {
            discard;
        }
        fragColor = vec4(min(col.rgb, vec3(1.0)), col.a);
        return;
    }

    gl_FragDepth = gl_FragCoord.z;
    vec4 color = texel * vertexColor * ColorModulator;
    if (color.a < 0.1) {
        discard;
    }
    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}

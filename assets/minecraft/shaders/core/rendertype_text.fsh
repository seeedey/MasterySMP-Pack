#version 330

#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>

uniform sampler2D Sampler0;

in float sphericalVertexDistance;
in float cylindricalVertexDistance;
in vec4 vertexColor;
in vec2 texCoord0;
flat in vec4 fxParams;

out vec4 fragColor;

// ---- the Mastery HUD ------------------------------------------------------------------------------------------------
// A gauge texel has alpha 247, which no other glyph uses. It is painted here rather than drawn, so everything stays on
// the pixel grid and one glyph can show any fill in any Mastery's colour.
//   texel: r = position along the bar, tip to slot (on the ring, the angle from the top)
//          g = its row, top to bottom
//          b = kind: 0 bar, 1 ring
//   text colour: r = fill, g = Mastery + 16 * mode, b = pulse (the ult's clock or a hit's flash)
// The text pipeline has no clock, so the plugin drives the pulse by resending the line.

const float HUD_ALPHA = 247.0;
const float TAU = 6.2831853;
const int MODE_IDLE = 0, MODE_ULT = 2, MODE_COOLDOWN = 3;
const vec3 HUD_HUE[9] = vec3[9](vec3(0.557, 0.878, 1.000), vec3(1.000, 0.290, 0.227), vec3(1.000, 0.698, 0.243),
        vec3(0.247, 0.878, 0.784), vec3(0.420, 0.851, 0.290), vec3(0.714, 0.471, 1.000),
        vec3(1.000, 0.498, 0.690), vec3(1.000, 0.949, 0.478), vec3(1.000, 0.478, 0.235));

vec4 hud(vec4 tex, vec4 p) {
    float along = tex.r, row = tex.g;
    int kind = int(tex.b * 255.0 + 0.5);
    int code = int(p.g * 255.0 + 0.5);
    int mode = code >> 4;
    float fill = p.r, pulse = p.b;
    vec3 hue = HUD_HUE[min(code & 15, 8)];
    bool ult = mode == MODE_ULT;

    if (mode == MODE_COOLDOWN) hue = vec3(dot(hue, vec3(0.3, 0.6, 0.1))) * 0.62;
    float flash = ult ? 0.0 : pulse;

    if (kind == 1) {
        // at rest the line is whole; otherwise it sweeps round with the bars
        float swept = mode == MODE_IDLE ? 1.0 : step(along, fill);
        vec3 col = mix(hue * 0.28, hue, swept);
        if (ult) col = mix(col, vec3(1.0), (0.5 + 0.5 * sin(pulse * TAU)) * 0.45);
        return vec4(mix(col, vec3(1.0), flash * 0.7), 1.0);
    }

    // the ult burns down toward the slot; everything else fills toward it
    float lit = ult ? step(1.0 - fill, along) * step(0.001, fill) : step(along, fill);
    if (lit < 0.5) return vec4(hue * 0.16 + 0.03, 1.0);

    // the experience bar's three rows
    vec3 col = row < 0.25 ? mix(hue, vec3(1.0), 0.42) : row < 0.75 ? hue : hue * 0.62;
    if (ult) col = mix(col, vec3(1.0), smoothstep(0.82, 1.0, sin(along * 11.0 - pulse * TAU * 2.0)) * 0.5);
    return vec4(mix(col, vec3(1.0), flash * 0.7), 1.0);
}

void main() {
    vec4 tex = texture(Sampler0, texCoord0);
    if (abs(tex.a * 255.0 - HUD_ALPHA) < 0.5) {
        vec4 painted = hud(tex, fxParams);
        if (painted.a < 0.01) discard;
        fragColor = vec4(painted.rgb, painted.a * fxParams.a);
        return;
    }
    vec4 color = tex * vertexColor * ColorModulator;
    if (color.a < 0.1) {
        discard;
    }
    fragColor = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, FogColor);
}

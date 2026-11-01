#version 330

#moj_import <minecraft:light.glsl>
#moj_import <minecraft:fog.glsl>
#moj_import <minecraft:dynamictransforms.glsl>
#moj_import <minecraft:projection.glsl>

// Vanilla 1.21.11 rendertype_item_entity_translucent_cull.vsh, plus Mastery SMP's marker effects (see the .fsh).
// Only the sky needs anything here: its quad is thrown over the whole screen, just in front of the far plane.
// Every other item is drawn exactly as vanilla.
//
// fxPos     camera-relative position in world orientation; for the sky, the eye ray at this corner of the screen
// fxLocal   x right, y up across the face. Every quad is four consecutive vertices, top left first, going down:
//           (0,1) (0,0) (1,0) (1,1)
// fxTint    the item's tint, custom_model_data colors[0]: the plugin's three parameters
// fxProjZW  the rows of ProjMat the fragment shader needs to write its own depth

in vec3 Position;
in vec4 Color;
in vec2 UV0;
in vec2 UV1;
in ivec2 UV2;
in vec3 Normal;

uniform sampler2D Sampler0;
uniform sampler2D Sampler2;

out float sphericalVertexDistance;
out float cylindricalVertexDistance;
out vec4 vertexColor;
out vec2 texCoord0;
out vec2 texCoord1;
out vec2 texCoord2;

out vec3 fxPos;
out vec2 fxLocal;
flat out vec4 fxTint;
flat out vec4 fxProjZW;

void main() {
    gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);

    sphericalVertexDistance = fog_spherical_distance(Position);
    cylindricalVertexDistance = fog_cylindrical_distance(Position);
    vertexColor = minecraft_mix_light(Light0_Direction, Light1_Direction, Normal, Color) * texelFetch(Sampler2, UV2 / 16, 0);
    texCoord0 = UV0;
    texCoord1 = UV1;
    texCoord2 = vec2(UV2);

    int corner = gl_VertexID & 3;
    fxLocal = vec2(float(corner >> 1), float(((corner + 1) >> 1) & 1 ^ 1));
    fxPos = Position;
    fxTint = Color;
    fxProjZW = vec4(ProjMat[2][2], ProjMat[3][2], ProjMat[2][3], ProjMat[3][3]);

    vec4 m = textureLod(Sampler0, UV0, 0.0) * 255.0;
    if (abs(m.a - 248.0) < 0.5 && abs(m.r - 13.0) < 0.5) {
        vec2 ndc = fxLocal * 2.0 - 1.0;
        gl_Position = vec4(ndc, 0.9999999, 1.0);
        vec4 ray = inverse(ProjMat) * vec4(ndc, 1.0, 1.0);
        fxPos = inverse(mat3(ModelViewMat)) * (ray.xyz / ray.w);
    }
}

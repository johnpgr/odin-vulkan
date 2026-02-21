#version 450

layout(push_constant) uniform PushConstants {
    vec4 rect;
    vec4 color;
} pc;

layout(location = 0) out vec4 v_color;

vec2 quad_vertices[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main() {
    vec2 p = quad_vertices[gl_VertexIndex];
    vec2 ndc = pc.rect.xy + p * pc.rect.zw;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_color = pc.color;
}

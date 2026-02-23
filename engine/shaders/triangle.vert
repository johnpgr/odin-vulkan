#version 450

struct QuadData {
    vec4 rect;
    vec4 color;
};

layout(std430, set = 0, binding = 0) readonly buffer QuadBuffer {
    QuadData quads[];
};

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
    QuadData q = quads[gl_InstanceIndex];
    vec2 p = quad_vertices[gl_VertexIndex];
    vec2 ndc = q.rect.xy + p * q.rect.zw;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_color = q.color;
}

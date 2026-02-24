#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
    vec4 tint_param;
} push;

layout(location = 0) out vec4 v_color;

void main() {
    gl_Position = push.mvp * vec4(in_position, 1.0);
    float strength = clamp(push.tint_param.x, 0.0, 1.0);
    vec4 tinted = in_color * push.color;
    v_color = mix(in_color, tinted, strength);
}

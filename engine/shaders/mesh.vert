#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
} push;

layout(location = 0) out vec4 v_color;

void main() {
    gl_Position = push.mvp * vec4(in_position, 1.0);
    v_color = in_color * push.color;
}

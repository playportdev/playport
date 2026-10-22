// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(location = 0) in vec4 color;
layout(set = 0, binding = 1) uniform Tint { vec4 tint; } u;
layout(location = 0) out vec4 o;
void main() { o = color * u.tint; }

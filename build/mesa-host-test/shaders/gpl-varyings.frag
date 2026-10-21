// SPDX-License-Identifier: GPL-3.0-or-later
// Reads two of four components of each of gpl-varyings.vert's outputs.
#version 450
layout(location = 0) in vec2 uv;
layout(location = 1) flat in ivec2 id;
layout(location = 0) out vec4 o;
void main() { o = vec4(uv, float(id.x), float(id.y)); }

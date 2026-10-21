// SPDX-License-Identifier: GPL-3.0-or-later
// A vertex shader linked to gpl-varyings.frag, which reads fewer components
// of its outputs (PLA-424: stages compiled apart must still match).
#version 450
layout(location = 0) in vec4 pos;
layout(location = 0) out vec4 uv;
layout(location = 1) flat out ivec4 id;
void main() {
   gl_Position = pos;
   uv = pos.yxwz;
   id = ivec4(gl_VertexIndex, gl_InstanceIndex, 7, -1);
}

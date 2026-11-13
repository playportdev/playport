// SPDX-License-Identifier: GPL-3.0-or-later
// pass.vert with a layer per instance, as a layered draw of a game's array
// (MESA_KK_EXPERIMENTAL=layer_clamp, PLA-880).
#version 450
#extension GL_ARB_shader_viewport_layer_array : require
layout(location = 0) in vec4 pos;
layout(location = 0) out vec4 color;
void main() {
   gl_Position = pos;
   gl_Layer = gl_InstanceIndex;
   color = vec4(pos.xy, float(gl_VertexIndex) / 64.0, float(gl_InstanceIndex));
}

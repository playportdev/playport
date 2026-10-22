// SPDX-License-Identifier: GPL-3.0-or-later
// pass.vert with a layer written: links with it compile the whole pipeline.
#version 450
#extension GL_ARB_shader_viewport_layer_array : require
layout(location = 0) in vec4 pos;
layout(location = 0) out vec4 color;
void main() {
   gl_Position = pos;
   gl_Layer = 0;
   color = vec4(pos.xy, float(gl_VertexIndex) / 64.0, float(gl_InstanceIndex));
}

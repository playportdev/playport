// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(location = 0) in vec4 pos;
layout(location = 0) out vec4 color;
void main() {
   gl_Position = pos;
   color = vec4(pos.xy, float(gl_VertexIndex) / 64.0, float(gl_InstanceIndex));
}

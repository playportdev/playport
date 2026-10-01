// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(lines) in;
layout(points, max_vertices = 2) out;
layout(location = 0) in vec4 color[];
layout(location = 0) flat out vec4 ocolor;
void main() {
   for (int i = 0; i < 2; i++) {
      gl_Position = gl_in[i].gl_Position;
      gl_PointSize = 2.0;
      ocolor = color[i];
      EmitVertex();
   }
}

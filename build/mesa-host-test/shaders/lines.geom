// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles) in;
layout(line_strip, max_vertices = 4) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
void main() {
   for (int i = 0; i < 4; i++) {
      gl_Position = gl_in[i % 3].gl_Position;
      ocolor = color[i % 3];
      EmitVertex();
   }
}

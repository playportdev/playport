// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles_adjacency) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
void main() {
   for (int i = 0; i < 6; i += 2) {
      gl_Position = gl_in[i].gl_Position;
      ocolor = color[i + 1];
      EmitVertex();
   }
}

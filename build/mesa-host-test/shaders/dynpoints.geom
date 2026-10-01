// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles) in;
layout(points, max_vertices = 8) out;
layout(location = 0) in vec4 color[];
layout(location = 0) flat out vec4 ocolor;
void main() {
   /* Data-dependent point count: a dynamic index buffer padded with ~0. */
   int n = 1 + int(color[0].z * 64.0) % 8;
   for (int i = 0; i < n; i++) {
      gl_Position = gl_in[i % 3].gl_Position;
      ocolor = color[i % 3];
      EmitVertex();
   }
}

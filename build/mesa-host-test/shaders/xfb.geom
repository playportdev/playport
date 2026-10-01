// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 12) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
layout(location = 1, xfb_buffer = 0, xfb_offset = 0, xfb_stride = 16) out vec4 captured;
void main() {
   /* Data-dependent count: needs the count shader and a prefix sum. */
   int n = 3 + int(color[0].x * 8.0) % 10;
   for (int i = 0; i < n; i++) {
      gl_Position = gl_in[i % 3].gl_Position;
      ocolor = color[i % 3];
      captured = color[i % 3] + vec4(i);
      EmitVertex();
   }
}

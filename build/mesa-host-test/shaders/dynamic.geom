// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 16) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
void main() {
   /* Data-dependent vertex count: the topology is not known statically. */
   int n = 3 + int(color[0].x * 8.0) % 12;
   for (int i = 0; i < n; i++) {
      gl_Position = gl_in[0].gl_Position + vec4(float(i & 1) * 0.1, float(i >> 1) * 0.1, 0, 0);
      ocolor = color[0];
      EmitVertex();
      if (i == 7)
         EndPrimitive();
   }
}

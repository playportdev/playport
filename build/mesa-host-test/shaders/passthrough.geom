// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
void main() {
   for (int i = 0; i < 3; i++) {
      gl_Position = gl_in[i].gl_Position;
      ocolor = color[i];
      EmitVertex();
   }
   EndPrimitive();
}

// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles, invocations = 4) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
void main() {
   for (int i = 0; i < 3; i++) {
      gl_Position = gl_in[i].gl_Position + vec4(float(gl_InvocationID) * 0.1, 0, 0, 0);
      ocolor = color[i];
      gl_Layer = 0;
      EmitVertex();
   }
}

// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor;
out float gl_ClipDistance[1];
out float gl_CullDistance[1];
void main() {
   for (int i = 0; i < 3; i++) {
      gl_Position = gl_in[i].gl_Position;
      gl_PrimitiveID = gl_PrimitiveIDIn * 2;
      gl_ClipDistance[0] = gl_Position.x;
      gl_CullDistance[0] = gl_Position.y;
      ocolor = color[i];
      EmitVertex();
   }
}

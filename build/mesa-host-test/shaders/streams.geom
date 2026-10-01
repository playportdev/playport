// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(points) in;
layout(points, max_vertices = 4) out;
layout(location = 0) in vec4 color[];
layout(location = 0, stream = 0) out vec4 ocolor;
layout(location = 1, stream = 1, xfb_buffer = 1, xfb_offset = 0, xfb_stride = 16) out vec4 side;
void main() {
   gl_Position = gl_in[0].gl_Position;
   ocolor = color[0];
   EmitStreamVertex(0);
   side = color[0] * 3.0;
   EmitStreamVertex(1);
}

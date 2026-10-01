// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(vertices = 3) out;
layout(location = 0) in vec4 color[];
layout(location = 0) out vec4 ocolor[];
void main() {
   gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;
   ocolor[gl_InvocationID] = color[gl_InvocationID];
   gl_TessLevelOuter[0] = 3.0; gl_TessLevelOuter[1] = 3.0; gl_TessLevelOuter[2] = 3.0;
   gl_TessLevelInner[0] = 3.0;
}

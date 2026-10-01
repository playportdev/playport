// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
layout(location = 0) in vec4 pos;
layout(location = 0) out vec4 color;
layout(xfb_buffer = 0, xfb_offset = 0, xfb_stride = 32) out gl_PerVertex { vec4 gl_Position; };
layout(location = 1, xfb_buffer = 0, xfb_offset = 16) out vec4 captured;
layout(location = 2, xfb_buffer = 1, xfb_offset = 0, xfb_stride = 8) out vec2 second;
void main() {
   gl_Position = pos;
   color = pos;
   captured = pos * 2.0;
   second = pos.xy;
}

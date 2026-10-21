// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-source blending: both sources of colour attachment 0.
#version 450
layout(location = 0) in vec4 color;
layout(location = 0, index = 0) out vec4 o;
layout(location = 0, index = 1) out vec4 o1;
void main() {
   o = color;
   o1 = color.wzyx;
}

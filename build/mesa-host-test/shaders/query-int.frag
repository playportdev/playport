// SPDX-License-Identifier: GPL-3.0-or-later
// Size and level queries of an int and a uint texture beside their fetches:
// the MSL names them texture2d<int> and texture2d<uint>.
#version 450
layout(set = 0, binding = 0) uniform isampler2D i;
layout(set = 0, binding = 1) uniform usampler2D u;
layout(location = 0) out vec4 color;
void main()
{
   ivec2 p = ivec2(gl_FragCoord.xy) % textureSize(i, 0);
   color = vec4(textureSize(u, 0), textureQueryLevels(i), textureQueryLevels(u)) +
           vec4(texelFetch(i, p, 0).x, texelFetch(u, p, 0).x, 0, 0);
}

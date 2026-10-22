// SPDX-License-Identifier: GPL-3.0-or-later
// Size, level and sample queries of float textures that nothing samples, as
// DXVK's D3D9 fetch4 path makes them: the MSL names each texture with its
// float element type, not the queries' int result.
#version 450
layout(set = 0, binding = 0) uniform sampler2D f;
layout(set = 0, binding = 1) uniform sampler2DMS fms;
layout(location = 0) out vec4 color;
void main()
{
   color = vec4(textureSize(f, 0), textureQueryLevels(f), textureSamples(fms));
}

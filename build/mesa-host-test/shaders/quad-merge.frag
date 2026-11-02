// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
// Derivatives, as an implicit-LOD sample takes them: the fragment shader
// needs quad helpers, so by default KosmicKrisp keeps Metal from merging
// triangles into shared quads in it (msl_disable_triangle_merge reads
// [[barycentric_coord]]); with MESA_KK_EXPERIMENTAL=no_quad_merge_block
// (mesa 0143) it does not.
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 o;
void main() { o = vec4(dFdx(color.xy), dFdy(color.zw)); }

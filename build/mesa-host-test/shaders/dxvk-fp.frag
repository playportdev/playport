// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
#extension GL_EXT_spirv_intrinsics : require
// Float maths as DXVK's dxbc-spirv gives it on KosmicKrisp (PLA-72): the
// SignedZeroInfNanPreserve execution mode for 32-bit floats, and, as for a
// D3D11 shader without refactoringAllowed, NoContraction (precise) on its
// operations; the last multiplication and its comparison are not precise.
spirv_execution_mode(capabilities = [4466], 4461, 32);
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 o;
void main() {
   precise vec4 m = color * color.wzyx;
   precise vec4 a = m + color;
   precise vec4 c = max(a, vec4(0.5));
   vec4 d = c * color.y;
   o = d.x < d.y ? fract(d) : inversesqrt(abs(d));
}

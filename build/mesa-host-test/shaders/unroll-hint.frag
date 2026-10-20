// SPDX-License-Identifier: GPL-3.0-or-later
#version 450
#extension GL_EXT_control_flow_attributes : require
// Two loops with an unroll hint: a lighting-style loop of up to 64 iterations
// that may break earlier, whose body is too large to unroll (mesa 0060 leaves
// it a loop; unrolled, it is 64 nested ifs), and a 4-iteration one that
// unrolls.
layout(location = 0) in vec4 color;
layout(location = 0) out vec4 o;
void main() {
   uint count = uint(color.w);
   vec4 acc = vec4(0.0);
   [[unroll]] for (uint l = 0u; l < 64u; ++l) {
      if (l >= count)
         break;
      float fl = float(l);
      vec3 pos = vec3(sin(fl), cos(fl * 1.3), fl * 0.25) * color.xyz;
      vec3 d = pos - gl_FragCoord.xyz;
      float dist2 = max(dot(d, d), 1e-4);
      float att = clamp(1.0 - dist2 * color.y, 0.0, 1.0);
      vec3 n = normalize(d);
      float ndl = max(dot(n, normalize(vec3(color.x, fl, 1.0))), 0.0);
      vec3 h = normalize(n + vec3(color.z, sin(fl * 0.7), cos(fl * 0.9)));
      float spec = pow(max(dot(n, h), 0.0), color.w + 1.0);
      vec3 colour = vec3(fract(fl * 0.37), fract(fl * 0.61), fl / 64.0);
      acc.rgb += colour * (ndl + spec) * att / dist2;
      acc.a += sqrt(att) * exp2(-dist2) + sin(dist2) * cos(ndl);
      vec3 r = reflect(-n, normalize(vec3(cos(fl), color.y, sin(fl * 0.5))));
      acc.rgb += r * spec * inversesqrt(dist2 + fl);
   }
   [[unroll]] for (uint k = 0u; k < 4u; ++k)
      acc[k] = acc[k] * 0.5 + color[k];
   o = acc;
}

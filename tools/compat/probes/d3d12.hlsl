// SPDX-License-Identifier: GPL-3.0-or-later
// The d3d12 probe's shaders (d3d12.c): a triangle with a colour per vertex.
// Compiled to Shader Model 5.0 bytecode by d3d12-shaders.sh into
// d3d12_dxbc.h, which is committed.
struct vs_in  { float2 pos : POSITION; float3 col : COLOR; };
struct vs_out { float4 pos : SV_POSITION; float3 col : COLOR; };

vs_out vs_main(vs_in i)
{
    vs_out o;
    o.pos = float4(i.pos, 0.0, 1.0);
    o.col = i.col;
    return o;
}

float4 ps_main(vs_out i) : SV_TARGET
{
    return float4(i.col, 1.0);
}

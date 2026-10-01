/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * The winemetal unix slot for Madeira's native D3D12 shader converter.
 *
 * DXMT 0cb97661's winemetal_unix.c dispatches one unix call to
 * madeira_ir_convert(), which Madeira defines in research/madeira-d3d12
 * on top of Apple's proprietary libmetalirconverter.dylib. Playport does not
 * ship that path (docs/LICENSING.md),
 * and its only caller, madeira_d3d12.dll, is not in the bundle. The slot
 * refuses instead, as the table's wow64 half already does.
 */

int madeira_ir_convert(void *args)
{
    (void)args;
    return (int)0xC0000002; /* STATUS_NOT_IMPLEMENTED */
}

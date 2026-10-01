/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Print what vkd3d-proton, built for Linux, makes of the Vulkan driver the
 * loader gives it: the feature levels D3D12CreateDevice accepts, the shader
 * model and the capability tiers that decide them. Run against the mock
 * KosmicKrisp (build/mesa-host-test/run-vkd3d.sh).
 *
 *    d3d12-caps
 */
#define COBJMACROS
#define INITGUID
#include <stdio.h>
#include "vkd3d_windows.h"
#include "vkd3d_d3d12.h"

int
main(void)
{
   static const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
      D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2,
   };
   ID3D12Device *device = NULL;

   /* vkd3d-proton hands out the live device of an adapter again without
    * checking the level, so each attempt starts with no device alive. */
   for (unsigned i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
      ID3D12Device *d = NULL;
      HRESULT hr = D3D12CreateDevice(NULL, levels[i], &IID_ID3D12Device,
                                     (void **)&d);
      printf("D3D12CreateDevice(%x_%x): %s\n", levels[i] >> 12,
             (levels[i] >> 8) & 0xf, SUCCEEDED(hr) ? "ok" : "fails");
      if (d)
         ID3D12Device_Release(d);
   }
   if (FAILED(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0,
                                &IID_ID3D12Device, (void **)&device)))
      return 1;

   D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
   ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS, &o,
                                    sizeof(o));
   D3D12_FEATURE_DATA_SHADER_MODEL sm = {D3D_SHADER_MODEL_6_9};
   ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_SHADER_MODEL, &sm,
                                    sizeof(sm));
   D3D12_FEATURE_DATA_D3D12_OPTIONS1 o1 = {0};
   ID3D12Device_CheckFeatureSupport(device, D3D12_FEATURE_D3D12_OPTIONS1, &o1,
                                    sizeof(o1));

   printf("HighestShaderModel %x.%x\n", sm.HighestShaderModel >> 4,
          sm.HighestShaderModel & 0xf);
   printf("ResourceBindingTier %d\n", o.ResourceBindingTier);
   printf("TiledResourcesTier %d\n", o.TiledResourcesTier);
   printf("TypedUAVLoadAdditionalFormats %d\n", o.TypedUAVLoadAdditionalFormats);
   printf("ROVsSupported %d\n", o.ROVsSupported);
   printf("ConservativeRasterizationTier %d\n", o.ConservativeRasterizationTier);
   printf("ResourceHeapTier %d\n", o.ResourceHeapTier);
   printf("WaveOps %d, WaveLaneCountMin %u, Int64ShaderOps %d\n", o1.WaveOps,
          o1.WaveLaneCountMin, o1.Int64ShaderOps);
   ID3D12Device_Release(device);
   return 0;
}

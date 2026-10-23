// SPDX-License-Identifier: GPL-3.0-or-later
// Optimized inspection seam using exactly the production RAII helper.
#include "dxvk_descriptor_stats.h"
extern "C" void descriptor_disabled_path(dxvk::DescriptorStats* stats, void (*operation)()) {
  dxvk::DescriptorScope scope(stats, dxvk::DescriptorOp::Prep);
  operation();
}

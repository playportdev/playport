// SPDX-License-Identifier: GPL-3.0-or-later
// Cross-compile only: inspect the real inline Vulkan wrappers with cached state.
#include "dxvk_cmdlist.h"
extern "C" void descriptor_update_path(dxvk::DxvkCommandList* list,
    uint32_t count, const VkWriteDescriptorSet* writes) {
  list->updateDescriptorSets(count, writes);
}
extern "C" void descriptor_template_path(dxvk::DxvkCommandList* list,
    VkDescriptorSet set, VkDescriptorUpdateTemplate update, const void* data) {
  list->updateDescriptorSetWithTemplate(set, update, data, 4);
}
extern "C" void descriptor_bind_path(dxvk::DxvkCommandList* list,
    const VkBindDescriptorSetsInfo* info) {
  list->cmdBindDescriptorSets(dxvk::DxvkCmdBuffer::ExecBuffer, info);
}

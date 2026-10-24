#include "vkd3d_descriptor_stats.h"
void descriptor_disabled_path(struct vkd3d_descriptor_stats *stats)
{
    struct vkd3d_descriptor_scope scope = vkd3d_descriptor_begin(stats, VKD3D_DS_PREP_GRAPHICS);
    vkd3d_descriptor_add(&scope, VKD3D_DS_TABLE_SLOTS, 7);
    vkd3d_descriptor_end(&scope);
}

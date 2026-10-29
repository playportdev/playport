// SPDX-License-Identifier: GPL-3.0-or-later
// PLA-474: standalone Mac diagnostic, not a Playport build or phone test.
// xcrun clang -fobjc-arc -O2 -mmacosx-version-min=26.0 -framework Foundation \
//   -framework Metal build/mesa-host-test/metal-copy-timestamps.m \
//   -o .work/metal-copy-timestamps && .work/metal-copy-timestamps
// Modes: 0 relaxed, 1 precise, 2 precise + intra-encoder barriers,
// 3 separate queue-ordered timestamp encoders (includes marker overhead).
// Each copy is verified after a shared event, before counters are resolved.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) { @autoreleasepool {
  id<MTLDevice> d = MTLCreateSystemDefaultDevice();
  printf("device=%s frequency=%llu\n", d.name.UTF8String, (unsigned long long)[d queryTimestampFrequency]);
  id<MTL4CommandQueue> q = [d newMTL4CommandQueue];
  id<MTLSharedEvent> event = [d newSharedEvent];
  uint64_t sequence = 0;
  for (int sizeIndex = 0; sizeIndex < 2; sizeIndex++) {
    NSUInteger size = sizeIndex ? 1024*1024 : 15360;
    id<MTLBuffer> src = [d newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBuffer> dst = [d newBufferWithLength:size options:MTLResourceStorageModeShared];
    memset(src.contents, 0x5a, size);
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.initialCapacity = 2;
    NSError *error = nil;
    id<MTLResidencySet> resident = [d newResidencySetWithDescriptor:rd error:&error];
    assert(resident); [resident addAllocation:src]; [resident addAllocation:dst]; [resident commit];
    [q addResidencySet:resident];
    for (int mode = 0; mode < 4; mode++) {
      double sum = 0, min = 1e30, max = 0; unsigned zero = 0;
      for (unsigned i = 0; i < 12; i++) { @autoreleasepool {
        memset(dst.contents, 0, size);
        id<MTL4CommandAllocator> alloc = [d newCommandAllocator];
        id<MTL4CommandBuffer> cb = [d newCommandBuffer];
        MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new];
        hd.type = MTL4CounterHeapTypeTimestamp; hd.count = 2;
        id<MTL4CounterHeap> heap = [d newCounterHeapWithDescriptor:hd error:&error]; assert(heap);
        [cb beginCommandBufferWithAllocator:alloc];
        id<MTL4ComputeCommandEncoder> enc = [cb computeCommandEncoder];
        MTL4TimestampGranularity gran = mode ? MTL4TimestampGranularityPrecise : MTL4TimestampGranularityRelaxed;
        [enc writeTimestampWithGranularity:gran intoHeap:heap atIndex:0];
        if (mode == 2) [enc barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit
          beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:MTL4VisibilityOptionResourceAlias];
        if (mode == 3) {
          [enc barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionResourceAlias];
          [enc endEncoding]; enc = [cb computeCommandEncoder];
        }
        [enc copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0 size:size];
        if (mode == 3) {
          [enc barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionResourceAlias];
          [enc endEncoding]; enc = [cb computeCommandEncoder];
        }
        if (mode == 2) [enc barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit
          beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:MTL4VisibilityOptionResourceAlias];
        [enc writeTimestampWithGranularity:gran intoHeap:heap atIndex:1];
        [enc endEncoding]; [cb endCommandBuffer];
        [q commit:&cb count:1]; [q signalEvent:event value:++sequence];
        assert([event waitUntilSignaledValue:sequence timeoutMS:5000]);
        assert(!memcmp(src.contents, dst.contents, size));
        NSData *data = [heap resolveCounterRange:NSMakeRange(0,2)]; assert(data.length == 16);
        const MTL4TimestampHeapEntry *ts = data.bytes;
        assert(ts[1].timestamp >= ts[0].timestamp);
        double us = (ts[1].timestamp-ts[0].timestamp) * 1e6 / [d queryTimestampFrequency];
        sum += us; min = fmin(min,us); max = fmax(max,us); zero += us == 0;
      }}
      printf("size=%lu mode=%d mean_us=%.3f min=%.3f max=%.3f zero=%u/12\n",(unsigned long)size,mode,sum/12,min,max,zero);
    }
    [q removeResidencySet:resident];
  }
}}

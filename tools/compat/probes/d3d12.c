/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * d3d12: a Direct3D 12 program that draws, for the ARM64 graphics path of a
 * native ARM64 child (PLA-518, decision 0170): vkd3d-proton's d3d12 and
 * DXVK's dxgi from Runtime/vulkan/aarch64-windows over sysarm64, the Vulkan
 * loader and winevulkan, KosmicKrisp.
 *
 *   device   DXGI factory, the first adapter (its name, IDs and memory),
 *            D3D12CreateDevice at feature level 11_0; the highest feature
 *            level and shader model the device reports, its binding tier
 *   swap     a 1280x720 window and a flip-discard swap chain of two
 *            R8G8B8A8 buffers on it (CreateSwapChainForHwnd on the queue)
 *   pipeline a root signature (D3D12SerializeRootSignature), a pipeline
 *            state from Shader Model 5.0 bytecode (d3d12.hlsl, embedded
 *            from d3d12_dxbc.h), a vertex buffer in an upload heap
 *   textures 24 64x64 textures, one colour per mip level, each a case of
 *            what a game's textures may be: R8G8B8A8, B8G8R8A8, BC1, BC2,
 *            BC3, BC7, A8 and R8 with a swizzle, the 16-bit formats, sRGB
 *            views of TYPELESS textures, 7 mip levels, placed in a default
 *            heap, copied from a buffer placed in an upload heap, written
 *            with WriteToSubresource in a custom (L0, write-back) heap,
 *            copied on a copy queue; a static point sampler or one from a
 *            sampler heap (point, or anisotropic). A format the device
 *            cannot sample is skipped. The architecture (UMA) and the BC
 *            formats' D3D12_FEATURE_FORMAT_SUPPORT are logged
 *   frames   for 5 seconds (`seconds N` on the command line for N): clear
 *            to dark blue, draw a red-green-blue triangle and two rows of
 *            quads, each sampling one texture, present with sync
 *            interval 1, wait for the frame's fence
 *   readback the last frame's back buffer copied to a readback buffer: a
 *            corner pixel must be the clear colour, the centre pixel the
 *            triangle's (not the clear colour, not black), and each quad's
 *            centre its texture's colour
 *
 * Each line goes to OutputDebugString and <dir>\<exe name>.log, with the
 * DLLs d3d12, d3d12core, dxgi, vulkan-1 and winevulkan resolved from (which
 * file the farm linked). The last line is "d3d12: done ok" and the exit code
 * 0, or "d3d12: done FAIL at <step>" and the step's code: 2 window, 3 DXGI,
 * 4 device, 5 swap chain, 6 pipeline, 7 a frame, 8 the pixels, 9 the
 * textures.
 *
 * Built with llvm-mingw for aarch64 (d3d12.exe) and x86-64
 * (d3d12-x86_64.exe, to check the program under desktop Wine) by
 * tools/compat/probes/build.sh.
 */
#define COBJMACROS
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d3d12_dxbc.h"

#define WIDTH 1280
#define HEIGHT 720
#define BUFFERS 2

static const float clear_colour[4] = { 0.0f, 0.2f, 0.4f, 1.0f };

struct vertex { float pos[2]; float col[3]; };

static const struct vertex triangle[3] = {
    { {  0.0f,  0.7f }, { 1.0f, 0.0f, 0.0f } },
    { {  0.7f, -0.6f }, { 0.0f, 1.0f, 0.0f } },
    { { -0.7f, -0.6f }, { 0.0f, 0.0f, 1.0f } },
};

static HANDLE log_file = INVALID_HANDLE_VALUE;

static void probe_log(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "d3d12: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static void log_module(const char *name)
{
    char path[MAX_PATH];
    HMODULE module = GetModuleHandleA(name);

    if (!module) probe_log("module %s: not loaded\n", name);
    else if (GetModuleFileNameA(module, path, sizeof(path))) probe_log("module %s: %s\n", name, path);
}

static struct {
    HWND window;
    IDXGIFactory4 *factory;
    IDXGIAdapter1 *adapter;
    ID3D12Device *device;
    ID3D12CommandQueue *queue;
    IDXGISwapChain3 *swap;
    UINT width, height;
    ID3D12DescriptorHeap *rtv_heap;
    UINT rtv_size;
    ID3D12Resource *buffers[BUFFERS];
    ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList *list;
    ID3D12Fence *fence;
    UINT64 fence_value;
    HANDLE fence_event;
    ID3D12RootSignature *root;
    ID3D12PipelineState *pipeline;
    ID3D12Resource *vertices;
    D3D12_VERTEX_BUFFER_VIEW vertex_view;
    ID3D12Resource *readback;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
    ID3D12RootSignature *tex_root, *heap_root;
    ID3D12PipelineState *tex_pipeline, *heap_pipeline;
    ID3D12Resource *quads;
    D3D12_VERTEX_BUFFER_VIEW quad_view;
    ID3D12DescriptorHeap *srv_heap, *sampler_heap;
    UINT srv_size, sampler_size;
    ID3D12Heap *texture_heap, *upload_heap;
    ID3D12Resource *staging, *placed_staging;
    ID3D12CommandQueue *copy_queue;
    ID3D12CommandAllocator *copy_allocator;
    ID3D12GraphicsCommandList *copy_list;
    ID3D12Fence *copy_fence;
} g;

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_CLOSE) return 0;
    return DefWindowProcA(hwnd, msg, wparam, lparam);
}

static int fail(const char *what, HRESULT hr)
{
    probe_log("%s failed: %#lx\n", what, (unsigned long)hr);
    if (g.device) probe_log("device removed reason: %#lx\n", (unsigned long)ID3D12Device_GetDeviceRemovedReason(g.device));
    return 0;
}

static int window_step(HINSTANCE inst)
{
    WNDCLASSA wc = { 0 };
    RECT rect = { 0, 0, WIDTH, HEIGHT };

    wc.lpfnWndProc = window_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "d3d12probe";
    if (!RegisterClassA(&wc)) return fail("RegisterClass", HRESULT_FROM_WIN32(GetLastError()));
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    g.window = CreateWindowExA(0, wc.lpszClassName, "d3d12 probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                               CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
                               NULL, NULL, inst, NULL);
    if (!g.window) return fail("CreateWindowEx", HRESULT_FROM_WIN32(GetLastError()));
    GetClientRect(g.window, &rect);
    probe_log("window: %p client %ldx%ld\n", (void *)g.window, rect.right, rect.bottom);
    return 1;
}

static int dxgi_step(void)
{
    DXGI_ADAPTER_DESC1 desc;
    char name[256];
    HRESULT hr;

    if (FAILED(hr = CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&g.factory))) return fail("CreateDXGIFactory2", hr);
    if (FAILED(hr = IDXGIFactory4_EnumAdapters1(g.factory, 0, &g.adapter))) return fail("EnumAdapters1(0)", hr);
    if (FAILED(hr = IDXGIAdapter1_GetDesc1(g.adapter, &desc))) return fail("GetDesc1", hr);
    WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, name, sizeof(name), NULL, NULL);
    probe_log("adapter: \"%s\" vendor %#x device %#x video memory %zu MiB shared %zu MiB flags %#x\n", name,
              desc.VendorId, desc.DeviceId, desc.DedicatedVideoMemory >> 20, desc.SharedSystemMemory >> 20, desc.Flags);
    log_module("dxgi.dll");
    return 1;
}

static const char *level_name(D3D_FEATURE_LEVEL level)
{
    switch (level) {
    case D3D_FEATURE_LEVEL_11_0: return "11_0";
    case D3D_FEATURE_LEVEL_11_1: return "11_1";
    case D3D_FEATURE_LEVEL_12_0: return "12_0";
    case D3D_FEATURE_LEVEL_12_1: return "12_1";
    case D3D_FEATURE_LEVEL_12_2: return "12_2";
    default: return "?";
    }
}

static int device_step(void)
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_12_0,
                                                D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2 };
    static const D3D_SHADER_MODEL models[] = { D3D_SHADER_MODEL_6_7, D3D_SHADER_MODEL_6_6, D3D_SHADER_MODEL_6_5,
                                               D3D_SHADER_MODEL_6_4, D3D_SHADER_MODEL_6_3, D3D_SHADER_MODEL_6_2,
                                               D3D_SHADER_MODEL_6_1, D3D_SHADER_MODEL_6_0, D3D_SHADER_MODEL_5_1 };
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { 0 };
    D3D12_FEATURE_DATA_SHADER_MODEL sm = { 0 };
    D3D12_FEATURE_DATA_D3D12_OPTIONS options = { 0 };
    HRESULT hr;
    size_t i;

    if (FAILED(hr = D3D12CreateDevice((IUnknown *)g.adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&g.device)))
        return fail("D3D12CreateDevice", hr);
    log_module("d3d12.dll");
    log_module("d3d12core.dll");
    log_module("vulkan-1.dll");
    log_module("winevulkan.dll");

    fl.NumFeatureLevels = sizeof(levels) / sizeof(levels[0]);
    fl.pFeatureLevelsRequested = levels;
    hr = ID3D12Device_CheckFeatureSupport(g.device, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
    if (FAILED(hr)) probe_log("feature level: query failed %#lx\n", (unsigned long)hr);
    else probe_log("feature level: %s (%#x)\n", level_name(fl.MaxSupportedFeatureLevel), fl.MaxSupportedFeatureLevel);

    /* The query fails for a model newer than the runtime knows: ask from the newest down. */
    for (i = 0; i < sizeof(models) / sizeof(models[0]); i++) {
        sm.HighestShaderModel = models[i];
        if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(g.device, D3D12_FEATURE_SHADER_MODEL, &sm, sizeof(sm)))) break;
    }
    if (i == sizeof(models) / sizeof(models[0])) probe_log("shader model: query failed\n");
    else probe_log("shader model: %u.%u\n", sm.HighestShaderModel >> 4, sm.HighestShaderModel & 0xf);

    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(g.device, D3D12_FEATURE_D3D12_OPTIONS, &options, sizeof(options))))
        probe_log("options: resource binding tier %d, tiled resources tier %d, resource heap tier %d\n",
                  options.ResourceBindingTier, options.TiledResourcesTier, options.ResourceHeapTier);
    return 1;
}

static int swap_step(void)
{
    D3D12_COMMAND_QUEUE_DESC queue_desc = { 0 };
    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = { 0 };
    DXGI_SWAP_CHAIN_DESC1 desc = { 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    IDXGISwapChain1 *swap1;
    HRESULT hr;
    UINT i;

    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(hr = ID3D12Device_CreateCommandQueue(g.device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&g.queue)))
        return fail("CreateCommandQueue", hr);

    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = BUFFERS;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    if (FAILED(hr = IDXGIFactory4_CreateSwapChainForHwnd(g.factory, (IUnknown *)g.queue, g.window, &desc, NULL, NULL, &swap1)))
        return fail("CreateSwapChainForHwnd", hr);
    hr = IDXGISwapChain1_QueryInterface(swap1, &IID_IDXGISwapChain3, (void **)&g.swap);
    IDXGISwapChain1_Release(swap1);
    if (FAILED(hr)) return fail("QueryInterface(IDXGISwapChain3)", hr);
    if (FAILED(hr = IDXGISwapChain3_GetDesc1(g.swap, &desc))) return fail("GetDesc1", hr);
    g.width = desc.Width;
    g.height = desc.Height;
    probe_log("swap chain: %ux%u, %u buffers, format %u\n", g.width, g.height, desc.BufferCount, desc.Format);

    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = BUFFERS;
    if (FAILED(hr = ID3D12Device_CreateDescriptorHeap(g.device, &heap_desc, &IID_ID3D12DescriptorHeap, (void **)&g.rtv_heap)))
        return fail("CreateDescriptorHeap", hr);
    g.rtv_size = ID3D12Device_GetDescriptorHandleIncrementSize(g.device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    g.rtv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(g.rtv_heap, &rtv);
    for (i = 0; i < BUFFERS; i++) {
        if (FAILED(hr = IDXGISwapChain3_GetBuffer(g.swap, i, &IID_ID3D12Resource, (void **)&g.buffers[i])))
            return fail("GetBuffer", hr);
        ID3D12Device_CreateRenderTargetView(g.device, g.buffers[i], NULL, rtv);
        rtv.ptr += g.rtv_size;
    }

    if (FAILED(hr = ID3D12Device_CreateCommandAllocator(g.device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                        &IID_ID3D12CommandAllocator, (void **)&g.allocator)))
        return fail("CreateCommandAllocator", hr);
    if (FAILED(hr = ID3D12Device_CreateFence(g.device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&g.fence)))
        return fail("CreateFence", hr);
    g.fence_event = CreateEventA(NULL, FALSE, FALSE, NULL);
    return 1;
}

static int pipeline_step(void)
{
    static const D3D12_INPUT_ELEMENT_DESC layout[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
        { "COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    };
    D3D12_ROOT_SIGNATURE_DESC root_desc = { 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso = { 0 };
    D3D12_HEAP_PROPERTIES heap = { 0 };
    D3D12_RESOURCE_DESC desc = { 0 }, back;
    ID3DBlob *blob = NULL, *errors = NULL;
    UINT64 total;
    void *data;
    HRESULT hr;

    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    if (FAILED(hr = D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors)))
        return fail("D3D12SerializeRootSignature", hr);
    hr = ID3D12Device_CreateRootSignature(g.device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob),
                                          &IID_ID3D12RootSignature, (void **)&g.root);
    ID3D10Blob_Release(blob);
    if (FAILED(hr)) return fail("CreateRootSignature", hr);

    pso.pRootSignature = g.root;
    pso.VS.pShaderBytecode = d3d12_vs;
    pso.VS.BytecodeLength = sizeof(d3d12_vs);
    pso.PS.pShaderBytecode = d3d12_ps;
    pso.PS.BytecodeLength = sizeof(d3d12_ps);
    pso.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pso.SampleMask = UINT_MAX;
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.RasterizerState.DepthClipEnable = TRUE;
    pso.InputLayout.pInputElementDescs = layout;
    pso.InputLayout.NumElements = sizeof(layout) / sizeof(layout[0]);
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.NumRenderTargets = 1;
    pso.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pso.SampleDesc.Count = 1;
    if (FAILED(hr = ID3D12Device_CreateGraphicsPipelineState(g.device, &pso, &IID_ID3D12PipelineState, (void **)&g.pipeline)))
        return fail("CreateGraphicsPipelineState", hr);
    probe_log("pipeline: root signature and pipeline state (vs %zu, ps %zu bytes of DXBC)\n",
              sizeof(d3d12_vs), sizeof(d3d12_ps));

    heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = sizeof(triangle);
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(hr = ID3D12Device_CreateCommittedResource(g.device, &heap, D3D12_HEAP_FLAG_NONE, &desc,
                                                         D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
                                                         &IID_ID3D12Resource, (void **)&g.vertices)))
        return fail("CreateCommittedResource(vertices)", hr);
    if (FAILED(hr = ID3D12Resource_Map(g.vertices, 0, NULL, &data))) return fail("Map(vertices)", hr);
    memcpy(data, triangle, sizeof(triangle));
    ID3D12Resource_Unmap(g.vertices, 0, NULL);
    g.vertex_view.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(g.vertices);
    g.vertex_view.SizeInBytes = sizeof(triangle);
    g.vertex_view.StrideInBytes = sizeof(triangle[0]);

    /* The readback buffer for the last frame's back buffer. */
    g.buffers[0]->lpVtbl->GetDesc(g.buffers[0], &back);
    ID3D12Device_GetCopyableFootprints(g.device, &back, 0, 1, 0, &g.footprint, NULL, NULL, &total);
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    desc.Width = total;
    if (FAILED(hr = ID3D12Device_CreateCommittedResource(g.device, &heap, D3D12_HEAP_FLAG_NONE, &desc,
                                                         D3D12_RESOURCE_STATE_COPY_DEST, NULL,
                                                         &IID_ID3D12Resource, (void **)&g.readback)))
        return fail("CreateCommittedResource(readback)", hr);

    if (FAILED(hr = ID3D12Device_CreateCommandList(g.device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, g.allocator, g.pipeline,
                                                   &IID_ID3D12GraphicsCommandList, (void **)&g.list)))
        return fail("CreateCommandList", hr);
    ID3D12GraphicsCommandList_Close(g.list);
    return 1;
}

static void barrier(ID3D12Resource *resource, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = { 0 };

    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = resource;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(g.list, 1, &b);
}

/* The texture checks: each texture one colour per mip level, sampled by a
 * quad in one of two rows (the top and the bottom of the window, away from
 * the triangle and the corner). A check's name says what it tries: the
 * format and the view's, mip levels, where the texture lives and how its
 * data got there, and the sampler. */
#define TEXTURES 24
#define ROW 12
#define TEX_SIZE 64
#define MAX_MIPS 7

enum placement { COMMITTED, PLACED, PLACED_UPLOAD, CUSTOM_WRITE, COPY_QUEUE };
enum sampler_kind { STATIC_POINT, HEAP_POINT, HEAP_ANISO };

#define COLOUR(r, g, b) .colour = { r, g, b, 255 }, .want = { r, g, b }

static struct texture {
    const char *name;
    DXGI_FORMAT format, view;   /* view 0: the resource's format */
    UINT mips;                  /* 0: 1 */
    enum placement placement;
    enum sampler_kind sampler;
    UINT mapping;               /* 0: the default */
    unsigned char colour[4];    /* level 0's texel (RGBA); other levels take level_colour */
    unsigned char want[3];
    int skipped;
    ID3D12Resource *resource;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint[MAX_MIPS];
    UINT rows[MAX_MIPS];
    UINT64 row_size[MAX_MIPS];
} textures[TEXTURES] = {
    { .name = "R8G8B8A8", .format = DXGI_FORMAT_R8G8B8A8_UNORM, COLOUR(255, 255, 0) },
    { .name = "BC1", .format = DXGI_FORMAT_BC1_UNORM, COLOUR(255, 0, 0) },
    { .name = "BC2", .format = DXGI_FORMAT_BC2_UNORM, COLOUR(0, 255, 0) },
    { .name = "BC3", .format = DXGI_FORMAT_BC3_UNORM, COLOUR(0, 0, 255) },
    { .name = "BC7", .format = DXGI_FORMAT_BC7_UNORM, COLOUR(255, 0, 255) },
    { .name = "BC1 placed", .format = DXGI_FORMAT_BC1_UNORM, .placement = PLACED, COLOUR(0, 255, 255) },
    { .name = "R8G8B8A8 placed", .format = DXGI_FORMAT_R8G8B8A8_UNORM, .placement = PLACED, COLOUR(255, 255, 255) },
    { .name = "R8G8B8A8 from a placed upload buffer", .format = DXGI_FORMAT_R8G8B8A8_UNORM, .placement = PLACED_UPLOAD,
      COLOUR(128, 0, 255) },
    { .name = "B8G8R8A8", .format = DXGI_FORMAT_B8G8R8A8_UNORM, COLOUR(255, 128, 0) },
    { .name = "B8G8R8A8_TYPELESS as UNORM_SRGB", .format = DXGI_FORMAT_B8G8R8A8_TYPELESS,
      .view = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, COLOUR(0, 255, 255) },
    { .name = "BC3_TYPELESS as UNORM_SRGB", .format = DXGI_FORMAT_BC3_TYPELESS, .view = DXGI_FORMAT_BC3_UNORM_SRGB,
      COLOUR(255, 0, 255) },
    { .name = "BC1_UNORM_SRGB", .format = DXGI_FORMAT_BC1_UNORM_SRGB, COLOUR(255, 255, 0) },
    { .name = "A8 as AAAA", .format = DXGI_FORMAT_A8_UNORM,
      .mapping = D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(3, 3, 3, 3), .colour = { 0, 0, 0, 255 }, .want = { 255, 255, 255 } },
    { .name = "R8 as RRR1", .format = DXGI_FORMAT_R8_UNORM,
      .mapping = D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(0, 0, 0, D3D12_SHADER_COMPONENT_MAPPING_FORCE_VALUE_1),
      .colour = { 128, 0, 0, 0 }, .want = { 128, 128, 128 } },
    { .name = "B5G6R5", .format = DXGI_FORMAT_B5G6R5_UNORM, COLOUR(255, 0, 255) },
    { .name = "B5G5R5A1", .format = DXGI_FORMAT_B5G5R5A1_UNORM, COLOUR(0, 255, 0) },
    { .name = "B4G4R4A4", .format = DXGI_FORMAT_B4G4R4A4_UNORM, COLOUR(0, 0, 255) },
    { .name = "BC1 7 mips", .format = DXGI_FORMAT_BC1_UNORM, .mips = 7, COLOUR(255, 255, 255) },
    { .name = "BC3 7 mips, anisotropic heap sampler", .format = DXGI_FORMAT_BC3_UNORM, .mips = 7,
      .sampler = HEAP_ANISO, COLOUR(255, 255, 255) },
    { .name = "R8G8B8A8 7 mips, anisotropic heap sampler", .format = DXGI_FORMAT_R8G8B8A8_UNORM, .mips = 7,
      .sampler = HEAP_ANISO, COLOUR(255, 255, 255) },
    { .name = "BC7 7 mips placed, point heap sampler", .format = DXGI_FORMAT_BC7_UNORM, .mips = 7, .placement = PLACED,
      .sampler = HEAP_POINT, COLOUR(255, 255, 255) },
    { .name = "R8G8B8A8 in a custom heap, WriteToSubresource", .format = DXGI_FORMAT_R8G8B8A8_UNORM,
      .placement = CUSTOM_WRITE, COLOUR(255, 255, 0) },
    { .name = "BC1 in a custom heap, WriteToSubresource", .format = DXGI_FORMAT_BC1_UNORM, .placement = CUSTOM_WRITE,
      COLOUR(255, 0, 0) },
    { .name = "BC1 copied on a copy queue", .format = DXGI_FORMAT_BC1_UNORM, .placement = COPY_QUEUE, COLOUR(0, 255, 0) },
};

/* The colour of mip level 1, 2, ... of a texture with mips: a level
 * sampled in place of level 0 (white) shows which one it was. */
static const unsigned char level_colour[MAX_MIPS - 1][4] = {
    { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
    { 255, 255, 0, 255 }, { 255, 0, 255, 255 }, { 0, 255, 255, 255 },
};

static unsigned short rgb565(const unsigned char c[4])
{
    return (unsigned short)(((c[0] >> 3) << 11) | ((c[1] >> 2) << 5) | (c[2] >> 3));
}

/* A BC1 colour block of one colour: colour0 the colour, colour1 black (so
 * colour0 > colour1, the four-colour mode BC2 and BC3 always use), every
 * index 0. */
static void bc1_colour(unsigned char *out, const unsigned char c[4])
{
    unsigned short c0 = rgb565(c);

    memset(out, 0, 8);
    out[0] = c0 & 0xff;
    out[1] = c0 >> 8;
}

static void put_bits(unsigned char *out, unsigned int *pos, unsigned int value, unsigned int count)
{
    for (unsigned int i = 0; i < count; i++, (*pos)++)
        if (value & (1u << i)) out[*pos / 8] |= (unsigned char)(1u << (*pos % 8));
}

/* A BC7 mode 6 block of one colour: endpoint 0 is (X << 1) | P0 per channel,
 * every index 0, so a channel of 255 is X 127 with P0 1, and 0 reads as 1. */
static void bc7_solid(unsigned char *out, const unsigned char c[4])
{
    unsigned int pos = 0;
    int i;

    memset(out, 0, 16);
    put_bits(out, &pos, 1u << 6, 7);                          /* mode 6 */
    for (i = 0; i < 3; i++) {
        put_bits(out, &pos, c[i] >> 1, 7);                    /* endpoint 0 */
        put_bits(out, &pos, c[i] >> 1, 7);                    /* endpoint 1 */
    }
    put_bits(out, &pos, 127, 7);                              /* alpha 0 */
    put_bits(out, &pos, 127, 7);                              /* alpha 1 */
    put_bits(out, &pos, 1, 1);                                /* P0 */
    put_bits(out, &pos, 1, 1);                                /* P1; indices stay 0 */
}

static void put16(unsigned char *out, unsigned int v)
{
    out[0] = v & 0xff;
    out[1] = (v >> 8) & 0xff;
}

/* One block (one texel for an uncompressed format) of colour c; its size. */
static UINT encode(DXGI_FORMAT format, const unsigned char c[4], unsigned char *out)
{
    switch (format) {
    case DXGI_FORMAT_BC1_UNORM:
    case DXGI_FORMAT_BC1_UNORM_SRGB:
        bc1_colour(out, c);
        return 8;
    case DXGI_FORMAT_BC2_UNORM:
        memset(out, 0xff, 8);                                 /* explicit alpha 15 */
        bc1_colour(out + 8, c);
        return 16;
    case DXGI_FORMAT_BC3_UNORM:
    case DXGI_FORMAT_BC3_TYPELESS:
        memset(out, 0, 8);
        out[0] = 255;                                         /* alpha0 255 > alpha1 0, indices 0 */
        bc1_colour(out + 8, c);
        return 16;
    case DXGI_FORMAT_BC7_UNORM:
        bc7_solid(out, c);
        return 16;
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
        out[0] = c[2];
        out[1] = c[1];
        out[2] = c[0];
        out[3] = c[3];
        return 4;
    case DXGI_FORMAT_A8_UNORM:
        out[0] = c[3];
        return 1;
    case DXGI_FORMAT_R8_UNORM:
        out[0] = c[0];
        return 1;
    case DXGI_FORMAT_B5G6R5_UNORM:
        put16(out, rgb565(c));
        return 2;
    case DXGI_FORMAT_B5G5R5A1_UNORM:
        put16(out, ((c[3] >> 7) << 15) | ((c[0] >> 3) << 10) | ((c[1] >> 3) << 5) | (c[2] >> 3));
        return 2;
    case DXGI_FORMAT_B4G4R4A4_UNORM:
        put16(out, ((c[3] >> 4) << 12) | ((c[0] >> 4) << 8) | ((c[1] >> 4) << 4) | (c[2] >> 4));
        return 2;
    default:
        memcpy(out, c, 4);
        return 4;
    }
}

static UINT format_support1(DXGI_FORMAT format)
{
    D3D12_FEATURE_DATA_FORMAT_SUPPORT s = { 0 };

    s.Format = format;
    if (FAILED(ID3D12Device_CheckFeatureSupport(g.device, D3D12_FEATURE_FORMAT_SUPPORT, &s, sizeof(s)))) return 0;
    return s.Support1;
}

static void log_format(DXGI_FORMAT format, const char *name)
{
    UINT s = format_support1(format);

    probe_log("format %s (%u): support1 %#x, texture2d %s, sample %s\n", name, format, s,
              s & D3D12_FORMAT_SUPPORT1_TEXTURE2D ? "yes" : "no", s & D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE ? "yes" : "no");
}

static int texture_pipeline(int heap_sampler, ID3D12RootSignature **root, ID3D12PipelineState **pipeline)
{
    static const D3D12_INPUT_ELEMENT_DESC layout[] = {
        { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
        { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    };
    D3D12_DESCRIPTOR_RANGE ranges[2] = {
        { D3D12_DESCRIPTOR_RANGE_TYPE_SRV, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND },
        { D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER, 1, 0, 0, D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND },
    };
    D3D12_ROOT_PARAMETER params[2] = { 0 };
    D3D12_STATIC_SAMPLER_DESC sampler = { 0 };
    D3D12_ROOT_SIGNATURE_DESC root_desc = { 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso = { 0 };
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT hr;

    for (int i = 0; i < 2; i++) {
        params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[i].DescriptorTable.NumDescriptorRanges = 1;
        params[i].DescriptorTable.pDescriptorRanges = &ranges[i];
        params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    }
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    root_desc.NumParameters = heap_sampler ? 2 : 1;
    root_desc.pParameters = params;
    root_desc.NumStaticSamplers = heap_sampler ? 0 : 1;
    root_desc.pStaticSamplers = heap_sampler ? NULL : &sampler;
    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    if (FAILED(hr = D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors)))
        return fail("D3D12SerializeRootSignature(textures)", hr);
    hr = ID3D12Device_CreateRootSignature(g.device, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob),
                                          &IID_ID3D12RootSignature, (void **)root);
    ID3D10Blob_Release(blob);
    if (FAILED(hr)) return fail("CreateRootSignature(textures)", hr);

    pso.pRootSignature = *root;
    pso.VS.pShaderBytecode = d3d12_tex_vs;
    pso.VS.BytecodeLength = sizeof(d3d12_tex_vs);
    pso.PS.pShaderBytecode = d3d12_tex_ps;
    pso.PS.BytecodeLength = sizeof(d3d12_tex_ps);
    pso.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pso.SampleMask = UINT_MAX;
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.RasterizerState.DepthClipEnable = TRUE;
    pso.InputLayout.pInputElementDescs = layout;
    pso.InputLayout.NumElements = sizeof(layout) / sizeof(layout[0]);
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.NumRenderTargets = 1;
    pso.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pso.SampleDesc.Count = 1;
    if (FAILED(hr = ID3D12Device_CreateGraphicsPipelineState(g.device, &pso, &IID_ID3D12PipelineState, (void **)pipeline)))
        return fail("CreateGraphicsPipelineState(textures)", hr);
    return 1;
}

static float quad_x0(int i) { return -0.95f + (i % ROW) * (1.9f / ROW) + 0.02f; }
static float quad_x1(int i) { return -0.95f + (i % ROW + 1) * (1.9f / ROW) - 0.02f; }
static float quad_y0(int i) { return i < ROW ? 0.75f : -0.95f; }
static float quad_y1(int i) { return i < ROW ? 0.95f : -0.75f; }

static int quad_vertices(void)
{
    struct { float pos[2]; float uv[2]; } v[TEXTURES * 6];
    D3D12_HEAP_PROPERTIES heap = { 0 };
    D3D12_RESOURCE_DESC desc = { 0 };
    void *data;
    HRESULT hr;

    for (int i = 0; i < TEXTURES; i++) {
        float x0 = quad_x0(i), x1 = quad_x1(i), y0 = quad_y0(i), y1 = quad_y1(i);
        float corners[6][4] = { { x0, y1, 0, 0 }, { x1, y1, 1, 0 }, { x0, y0, 0, 1 },
                                { x1, y1, 1, 0 }, { x1, y0, 1, 1 }, { x0, y0, 0, 1 } };
        for (int j = 0; j < 6; j++) memcpy(&v[i * 6 + j], corners[j], sizeof(corners[j]));
    }
    heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = sizeof(v);
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (FAILED(hr = ID3D12Device_CreateCommittedResource(g.device, &heap, D3D12_HEAP_FLAG_NONE, &desc,
                                                         D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
                                                         &IID_ID3D12Resource, (void **)&g.quads)))
        return fail("CreateCommittedResource(quads)", hr);
    if (FAILED(hr = ID3D12Resource_Map(g.quads, 0, NULL, &data))) return fail("Map(quads)", hr);
    memcpy(data, v, sizeof(v));
    ID3D12Resource_Unmap(g.quads, 0, NULL);
    g.quad_view.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(g.quads);
    g.quad_view.SizeInBytes = sizeof(v);
    g.quad_view.StrideInBytes = sizeof(v[0]);
    return 1;
}

static UINT mips(const struct texture *t) { return t->mips ? t->mips : 1; }

/* Level level's rows of texture t at base, each row row_pitch bytes apart
 * (the footprint's, or tight). */
static void fill_level(unsigned char *base, UINT64 row_pitch, const struct texture *t, UINT level)
{
    unsigned char block[16];
    UINT size = encode(t->format, level ? level_colour[level - 1] : t->colour, block);

    for (UINT y = 0; y < t->rows[level]; y++)
        for (UINT64 x = 0; x + size <= t->row_size[level]; x += size) memcpy(base + y * row_pitch + x, block, size);
}

static int create_texture(struct texture *t, UINT64 *texture_offset)
{
    D3D12_HEAP_PROPERTIES props = { 0 };
    D3D12_RESOURCE_DESC desc = { 0 };
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COPY_DEST;
    HRESULT hr;

    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = TEX_SIZE;
    desc.Height = TEX_SIZE;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = (UINT16)mips(t);
    desc.Format = t->format;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    props.Type = D3D12_HEAP_TYPE_DEFAULT;
    if (t->placement == CUSTOM_WRITE) {
        props.Type = D3D12_HEAP_TYPE_CUSTOM;
        props.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_WRITE_BACK;
        props.MemoryPoolPreference = D3D12_MEMORY_POOL_L0;
    }
    if (t->placement == CUSTOM_WRITE || t->placement == COPY_QUEUE) state = D3D12_RESOURCE_STATE_COMMON;
    if (t->placement == PLACED) {
        hr = ID3D12Device_CreatePlacedResource(g.device, g.texture_heap, *texture_offset, &desc, state, NULL,
                                               &IID_ID3D12Resource, (void **)&t->resource);
        *texture_offset += D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    } else {
        hr = ID3D12Device_CreateCommittedResource(g.device, &props, D3D12_HEAP_FLAG_NONE, &desc, state, NULL,
                                                  &IID_ID3D12Resource, (void **)&t->resource);
    }
    if (FAILED(hr)) {
        probe_log("texture %s: create failed\n", t->name);
        return fail(t->placement == PLACED ? "CreatePlacedResource" : "CreateCommittedResource", hr);
    }
    return 1;
}

/* A custom-heap texture's levels through Map and WriteToSubresource, as a
 * program that knows the adapter is UMA may fill one. */
static int write_texture(struct texture *t)
{
    for (UINT level = 0; level < mips(t); level++) {
        UINT64 size = t->rows[level] * t->row_size[level];
        unsigned char *data = malloc(size);
        HRESULT hr;

        if (!data) return fail("malloc", E_OUTOFMEMORY);
        fill_level(data, t->row_size[level], t, level);
        if (FAILED(hr = ID3D12Resource_Map(t->resource, level, NULL, NULL))) {
            free(data);
            return fail("Map(custom texture)", hr);
        }
        hr = ID3D12Resource_WriteToSubresource(t->resource, level, NULL, data, (UINT)t->row_size[level], (UINT)size);
        ID3D12Resource_Unmap(t->resource, level, NULL);
        free(data);
        if (FAILED(hr)) return fail("WriteToSubresource", hr);
    }
    return 1;
}

static void copy_levels(ID3D12GraphicsCommandList *list, struct texture *t, ID3D12Resource *staging)
{
    for (UINT level = 0; level < mips(t); level++) {
        D3D12_TEXTURE_COPY_LOCATION dst = { 0 }, src = { 0 };

        src.pResource = staging;
        src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src.PlacedFootprint = t->footprint[level];
        dst.pResource = t->resource;
        dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst.SubresourceIndex = level;
        ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    }
}

static ID3D12Resource *upload_buffer(ID3D12Heap *heap, UINT64 size)
{
    D3D12_HEAP_PROPERTIES props = { 0 };
    D3D12_RESOURCE_DESC buf = { 0 };
    ID3D12Resource *resource = NULL;
    HRESULT hr;

    props.Type = D3D12_HEAP_TYPE_UPLOAD;
    buf.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    buf.Width = size ? size : 256;
    buf.Height = 1;
    buf.DepthOrArraySize = 1;
    buf.MipLevels = 1;
    buf.SampleDesc.Count = 1;
    buf.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    if (heap) hr = ID3D12Device_CreatePlacedResource(g.device, heap, 0, &buf, D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
                                                     &IID_ID3D12Resource, (void **)&resource);
    else hr = ID3D12Device_CreateCommittedResource(g.device, &props, D3D12_HEAP_FLAG_NONE, &buf,
                                                   D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource,
                                                   (void **)&resource);
    if (FAILED(hr)) fail(heap ? "CreatePlacedResource(staging)" : "CreateCommittedResource(staging)", hr);
    return resource;
}

static int textures_step(void)
{
    D3D12_FEATURE_DATA_ARCHITECTURE arch = { 0 };
    D3D12_HEAP_DESC heap_desc = { 0 };
    D3D12_DESCRIPTOR_HEAP_DESC heap = { 0 };
    D3D12_SAMPLER_DESC sampler = { 0 };
    D3D12_COMMAND_QUEUE_DESC queue_desc = { 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE cpu;
    UINT64 staging_size = 0, placed_staging_size = 0, texture_offset = 0;
    unsigned char *staging, *placed_staging;
    ID3D12CommandList *lists[1];
    HRESULT hr;
    int i, skipped = 0;

    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(g.device, D3D12_FEATURE_ARCHITECTURE, &arch, sizeof(arch))))
        probe_log("architecture: tile based %d, UMA %d, cache coherent UMA %d\n", arch.TileBasedRenderer, arch.UMA,
                  arch.CacheCoherentUMA);
    log_format(DXGI_FORMAT_BC1_UNORM, "BC1_UNORM");
    log_format(DXGI_FORMAT_BC2_UNORM, "BC2_UNORM");
    log_format(DXGI_FORMAT_BC3_UNORM, "BC3_UNORM");
    log_format(DXGI_FORMAT_BC4_UNORM, "BC4_UNORM");
    log_format(DXGI_FORMAT_BC5_UNORM, "BC5_UNORM");
    log_format(DXGI_FORMAT_BC7_UNORM, "BC7_UNORM");
    if (!texture_pipeline(0, &g.tex_root, &g.tex_pipeline) || !texture_pipeline(1, &g.heap_root, &g.heap_pipeline) ||
        !quad_vertices())
        return 0;

    /* A default heap for the placed textures, 64 KB apart (the default
     * placement alignment), and an upload heap for one staging buffer. */
    heap_desc.SizeInBytes = 4 * D3D12_DEFAULT_RESOURCE_PLACEMENT_ALIGNMENT;
    heap_desc.Properties.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap_desc.Flags = D3D12_HEAP_FLAG_ALLOW_ONLY_NON_RT_DS_TEXTURES;
    if (FAILED(hr = ID3D12Device_CreateHeap(g.device, &heap_desc, &IID_ID3D12Heap, (void **)&g.texture_heap)))
        return fail("CreateHeap(default, textures)", hr);
    heap_desc.Properties.Type = D3D12_HEAP_TYPE_UPLOAD;
    heap_desc.Flags = D3D12_HEAP_FLAG_ALLOW_ONLY_BUFFERS;
    if (FAILED(hr = ID3D12Device_CreateHeap(g.device, &heap_desc, &IID_ID3D12Heap, (void **)&g.upload_heap)))
        return fail("CreateHeap(upload, buffers)", hr);

    heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heap.NumDescriptors = TEXTURES;
    heap.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (FAILED(hr = ID3D12Device_CreateDescriptorHeap(g.device, &heap, &IID_ID3D12DescriptorHeap, (void **)&g.srv_heap)))
        return fail("CreateDescriptorHeap(SRV)", hr);
    g.srv_size = ID3D12Device_GetDescriptorHandleIncrementSize(g.device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

    /* The heap samplers: 0 point and clamp, 1 anisotropic (16) and wrap. */
    heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
    heap.NumDescriptors = 2;
    if (FAILED(hr = ID3D12Device_CreateDescriptorHeap(g.device, &heap, &IID_ID3D12DescriptorHeap,
                                                      (void **)&g.sampler_heap)))
        return fail("CreateDescriptorHeap(sampler)", hr);
    g.sampler_size = ID3D12Device_GetDescriptorHandleIncrementSize(g.device, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    g.sampler_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(g.sampler_heap, &cpu);
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    ID3D12Device_CreateSampler(g.device, &sampler, cpu);
    cpu.ptr += g.sampler_size;
    sampler.Filter = D3D12_FILTER_ANISOTROPIC;
    sampler.MaxAnisotropy = 16;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
    ID3D12Device_CreateSampler(g.device, &sampler, cpu);

    g.srv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(g.srv_heap, &cpu);
    for (i = 0; i < TEXTURES; i++, cpu.ptr += g.srv_size) {
        struct texture *t = &textures[i];
        DXGI_FORMAT view = t->view ? t->view : t->format;
        UINT need = D3D12_FORMAT_SUPPORT1_TEXTURE2D | D3D12_FORMAT_SUPPORT1_SHADER_SAMPLE;
        D3D12_SHADER_RESOURCE_VIEW_DESC srv = { 0 };
        D3D12_RESOURCE_DESC desc;
        UINT64 *size = t->placement == PLACED_UPLOAD ? &placed_staging_size : &staging_size;
        UINT64 total;

        if (t->skipped || (format_support1(view) & need) != need) {
            if (!t->skipped) t->skipped = 1;
            skipped++;
            continue;
        }
        if (!create_texture(t, &texture_offset)) return 0;
        t->resource->lpVtbl->GetDesc(t->resource, &desc);
        *size = (*size + D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT - 1) & ~(UINT64)(D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT - 1);
        ID3D12Device_GetCopyableFootprints(g.device, &desc, 0, mips(t), *size, t->footprint, t->rows, t->row_size, &total);
        if (t->placement != CUSTOM_WRITE) *size = t->footprint[0].Offset + total;

        srv.Format = view;
        srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = t->mapping ? t->mapping : D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.Texture2D.MipLevels = t->mips ? (UINT)-1 : 1;
        ID3D12Device_CreateShaderResourceView(g.device, t->resource, &srv, cpu);
    }

    if (!(g.staging = upload_buffer(NULL, staging_size))) return 0;
    if (!(g.placed_staging = upload_buffer(g.upload_heap, placed_staging_size))) return 0;
    if (FAILED(hr = ID3D12Resource_Map(g.staging, 0, NULL, (void **)&staging))) return fail("Map(staging)", hr);
    if (FAILED(hr = ID3D12Resource_Map(g.placed_staging, 0, NULL, (void **)&placed_staging)))
        return fail("Map(placed staging)", hr);
    for (i = 0; i < TEXTURES; i++) {
        struct texture *t = &textures[i];

        if (t->skipped) continue;
        if (t->placement == CUSTOM_WRITE) {
            if (!write_texture(t)) return 0;
            continue;
        }
        for (UINT level = 0; level < mips(t); level++)
            fill_level((t->placement == PLACED_UPLOAD ? placed_staging : staging) + t->footprint[level].Offset,
                       t->footprint[level].Footprint.RowPitch, t, level);
    }
    ID3D12Resource_Unmap(g.staging, 0, NULL);
    ID3D12Resource_Unmap(g.placed_staging, 0, NULL);

    /* Copy-queue uploads first, then the direct queue waits for them. */
    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_COPY;
    if (FAILED(hr = ID3D12Device_CreateCommandQueue(g.device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&g.copy_queue)))
        return fail("CreateCommandQueue(copy)", hr);
    if (FAILED(hr = ID3D12Device_CreateCommandAllocator(g.device, D3D12_COMMAND_LIST_TYPE_COPY,
                                                        &IID_ID3D12CommandAllocator, (void **)&g.copy_allocator)))
        return fail("CreateCommandAllocator(copy)", hr);
    if (FAILED(hr = ID3D12Device_CreateCommandList(g.device, 0, D3D12_COMMAND_LIST_TYPE_COPY, g.copy_allocator, NULL,
                                                   &IID_ID3D12GraphicsCommandList, (void **)&g.copy_list)))
        return fail("CreateCommandList(copy)", hr);
    if (FAILED(hr = ID3D12Device_CreateFence(g.device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&g.copy_fence)))
        return fail("CreateFence(copy)", hr);
    for (i = 0; i < TEXTURES; i++)
        if (!textures[i].skipped && textures[i].placement == COPY_QUEUE) copy_levels(g.copy_list, &textures[i], g.staging);
    if (FAILED(hr = ID3D12GraphicsCommandList_Close(g.copy_list))) return fail("CommandList Close(copy)", hr);
    lists[0] = (ID3D12CommandList *)g.copy_list;
    ID3D12CommandQueue_ExecuteCommandLists(g.copy_queue, 1, lists);
    if (FAILED(hr = ID3D12CommandQueue_Signal(g.copy_queue, g.copy_fence, 1))) return fail("Signal(copy)", hr);

    if (FAILED(hr = ID3D12CommandAllocator_Reset(g.allocator))) return fail("CommandAllocator Reset", hr);
    if (FAILED(hr = ID3D12GraphicsCommandList_Reset(g.list, g.allocator, NULL))) return fail("CommandList Reset", hr);
    for (i = 0; i < TEXTURES; i++) {
        struct texture *t = &textures[i];

        if (t->skipped) continue;
        if (t->placement == CUSTOM_WRITE || t->placement == COPY_QUEUE) {
            barrier(t->resource, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            continue;
        }
        copy_levels(g.list, t, t->placement == PLACED_UPLOAD ? g.placed_staging : g.staging);
        barrier(t->resource, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    }
    if (FAILED(hr = ID3D12GraphicsCommandList_Close(g.list))) return fail("CommandList Close(upload)", hr);
    if (FAILED(hr = ID3D12CommandQueue_Wait(g.queue, g.copy_fence, 1))) return fail("Wait(copy)", hr);
    lists[0] = (ID3D12CommandList *)g.list;
    ID3D12CommandQueue_ExecuteCommandLists(g.queue, 1, lists);
    if (FAILED(hr = ID3D12CommandQueue_Signal(g.queue, g.fence, ++g.fence_value))) return fail("Signal(upload)", hr);
    if (FAILED(hr = ID3D12Fence_SetEventOnCompletion(g.fence, g.fence_value, g.fence_event)))
        return fail("SetEventOnCompletion(upload)", hr);
    if (WaitForSingleObject(g.fence_event, 5000) != WAIT_OBJECT_0) return fail("upload fence wait (5 s)", E_FAIL);
    probe_log("textures: %d made, %d skipped; %llu + %llu bytes staged\n", TEXTURES - skipped,
              skipped, (unsigned long long)staging_size, (unsigned long long)placed_staging_size);
    return 1;
}

static void draw_quads(void)
{
    D3D12_GPU_DESCRIPTOR_HANDLE srv, samplers;
    ID3D12DescriptorHeap *heaps[2] = { g.srv_heap, g.sampler_heap };
    UINT heap_count = 1;

    /* The sampler heap only when a check takes its sampler from it */
    for (int i = 0; i < TEXTURES; i++)
        if (!textures[i].skipped && textures[i].sampler != STATIC_POINT) heap_count = 2;
    ID3D12GraphicsCommandList_SetDescriptorHeaps(g.list, heap_count, heaps);
    ID3D12GraphicsCommandList_IASetVertexBuffers(g.list, 0, 1, &g.quad_view);
    g.srv_heap->lpVtbl->GetGPUDescriptorHandleForHeapStart(g.srv_heap, &srv);
    g.sampler_heap->lpVtbl->GetGPUDescriptorHandleForHeapStart(g.sampler_heap, &samplers);
    for (int i = 0; i < TEXTURES; i++, srv.ptr += g.srv_size) {
        const struct texture *t = &textures[i];
        D3D12_GPU_DESCRIPTOR_HANDLE sampler = samplers;

        if (t->skipped) continue;
        if (t->sampler == STATIC_POINT) {
            ID3D12GraphicsCommandList_SetPipelineState(g.list, g.tex_pipeline);
            ID3D12GraphicsCommandList_SetGraphicsRootSignature(g.list, g.tex_root);
        } else {
            ID3D12GraphicsCommandList_SetPipelineState(g.list, g.heap_pipeline);
            ID3D12GraphicsCommandList_SetGraphicsRootSignature(g.list, g.heap_root);
            if (t->sampler == HEAP_ANISO) sampler.ptr += g.sampler_size;
            ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(g.list, 1, sampler);
        }
        ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(g.list, 0, srv);
        ID3D12GraphicsCommandList_DrawInstanced(g.list, 6, 1, i * 6, 0);
    }
}

static int frame(int last)
{
    UINT index = IDXGISwapChain3_GetCurrentBackBufferIndex(g.swap);
    ID3D12Resource *buffer = g.buffers[index];
    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_VIEWPORT viewport = { 0, 0, (float)g.width, (float)g.height, 0, 1 };
    D3D12_RECT scissor = { 0, 0, (LONG)g.width, (LONG)g.height };
    ID3D12CommandList *lists[1];
    HRESULT hr;

    if (FAILED(hr = ID3D12CommandAllocator_Reset(g.allocator))) return fail("CommandAllocator Reset", hr);
    if (FAILED(hr = ID3D12GraphicsCommandList_Reset(g.list, g.allocator, g.pipeline))) return fail("CommandList Reset", hr);
    g.rtv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(g.rtv_heap, &rtv);
    rtv.ptr += index * g.rtv_size;

    barrier(buffer, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
    ID3D12GraphicsCommandList_OMSetRenderTargets(g.list, 1, &rtv, FALSE, NULL);
    ID3D12GraphicsCommandList_ClearRenderTargetView(g.list, rtv, clear_colour, 0, NULL);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(g.list, g.root);
    ID3D12GraphicsCommandList_RSSetViewports(g.list, 1, &viewport);
    ID3D12GraphicsCommandList_RSSetScissorRects(g.list, 1, &scissor);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(g.list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_IASetVertexBuffers(g.list, 0, 1, &g.vertex_view);
    ID3D12GraphicsCommandList_DrawInstanced(g.list, 3, 1, 0, 0);
    draw_quads();
    if (last) {
        D3D12_TEXTURE_COPY_LOCATION dst = { 0 }, src = { 0 };

        barrier(buffer, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_COPY_SOURCE);
        dst.pResource = g.readback;
        dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        dst.PlacedFootprint = g.footprint;
        src.pResource = buffer;
        src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        ID3D12GraphicsCommandList_CopyTextureRegion(g.list, &dst, 0, 0, 0, &src, NULL);
        barrier(buffer, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_PRESENT);
    } else {
        barrier(buffer, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
    }
    if (FAILED(hr = ID3D12GraphicsCommandList_Close(g.list))) return fail("CommandList Close", hr);
    lists[0] = (ID3D12CommandList *)g.list;
    ID3D12CommandQueue_ExecuteCommandLists(g.queue, 1, lists);
    if (FAILED(hr = IDXGISwapChain3_Present(g.swap, 1, 0))) return fail("Present", hr);
    if (FAILED(hr = ID3D12CommandQueue_Signal(g.queue, g.fence, ++g.fence_value))) return fail("Signal", hr);
    if (ID3D12Fence_GetCompletedValue(g.fence) < g.fence_value) {
        if (FAILED(hr = ID3D12Fence_SetEventOnCompletion(g.fence, g.fence_value, g.fence_event)))
            return fail("SetEventOnCompletion", hr);
        if (WaitForSingleObject(g.fence_event, 5000) != WAIT_OBJECT_0) return fail("fence wait (5 s)", E_FAIL);
    }
    return 1;
}

static int frames_step(DWORD seconds)
{
    DWORD start = GetTickCount(), first = 0, elapsed;
    unsigned int count = 0;
    MSG msg;

    do {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        elapsed = GetTickCount() - start;
        if (!frame(elapsed >= seconds * 1000)) {
            probe_log("frames: %u presented before the failure\n", count);
            return 0;
        }
        if (!count++) {
            first = GetTickCount() - start;
            probe_log("frames: first frame presented after %lu ms\n", first);
        }
    } while (elapsed < seconds * 1000);
    elapsed = GetTickCount() - start;
    probe_log("frames: %u presented in %lu ms (%.1f a second)\n", count, elapsed,
              elapsed > first ? (count - 1) * 1000.0 / (elapsed - first) : 0.0);
    return 1;
}

static const unsigned char *pixel(const unsigned char *data, UINT x, UINT y)
{
    return data + g.footprint.Offset + (size_t)y * g.footprint.Footprint.RowPitch + (size_t)x * 4;
}

static int close_to(int a, int b) { return abs(a - b) <= 2; }

static int pixels_step(void)
{
    const unsigned char *data, *corner, *centre;
    D3D12_RANGE none = { 0, 0 };
    int clear[3], ok;
    HRESULT hr;

    if (FAILED(hr = ID3D12Resource_Map(g.readback, 0, NULL, (void **)&data))) return fail("Map(readback)", hr);
    corner = pixel(data, 4, 4);
    centre = pixel(data, g.width / 2, g.height / 2);
    for (int i = 0; i < 3; i++) clear[i] = (int)(clear_colour[i] * 255.0f + 0.5f);
    probe_log("pixels: corner (4,4) = %u,%u,%u,%u; centre (%u,%u) = %u,%u,%u,%u; clear colour %d,%d,%d\n",
              corner[0], corner[1], corner[2], corner[3], g.width / 2, g.height / 2,
              centre[0], centre[1], centre[2], centre[3], clear[0], clear[1], clear[2]);
    ok = close_to(corner[0], clear[0]) && close_to(corner[1], clear[1]) && close_to(corner[2], clear[2]) &&
         !(close_to(centre[0], clear[0]) && close_to(centre[1], clear[1]) && close_to(centre[2], clear[2])) &&
         centre[0] + centre[1] + centre[2] > 64;
    probe_log("CHECK the corner is the clear colour and the centre the triangle's: %s\n", ok ? "ok" : "FAIL");
    for (int i = 0; i < TEXTURES; i++) {
        const struct texture *t = &textures[i];
        UINT x = (UINT)((quad_x0(i) + quad_x1(i)) / 2 * 0.5f * g.width + g.width / 2.0f);
        UINT y = (UINT)((1.0f - (quad_y0(i) + quad_y1(i)) / 2) * 0.5f * g.height);
        const unsigned char *p = pixel(data, x, y);
        int match = close_to(p[0], t->want[0]) && close_to(p[1], t->want[1]) && close_to(p[2], t->want[2]);

        if (t->skipped) {
            probe_log("CHECK texture %s (format %u): skipped, %s\n", t->name, t->format,
                      t->skipped == 2 ? "left out on the command line" : "the view format is not sampleable");
            continue;
        }
        probe_log("CHECK texture %s (format %u) sampled at (%u,%u) = %u,%u,%u,%u, want %u,%u,%u: %s\n", t->name,
                  t->format, x, y, p[0], p[1], p[2], p[3], t->want[0], t->want[1], t->want[2], match ? "ok" : "FAIL");
        ok = ok && match;
    }
    ID3D12Resource_Unmap(g.readback, 0, &none);
    return ok;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char exe[MAX_PATH], path[MAX_PATH + 8], *dot, *skip;
    DWORD seconds = 5;
    USHORT process = 0, native = 0;
    int step = 0;

    if (!strncmp(cmdline, "seconds ", 8)) seconds = strtoul(cmdline + 8, NULL, 0);
    /* `skip I,J,...`: leave out those texture checks (their index from 0) */
    if ((skip = strstr(cmdline, "skip "))) {
        for (char *p = skip + 5; *p;) {
            char *end;
            unsigned long i = strtoul(p, &end, 0);
            if (end == p) break;
            if (i < TEXTURES) textures[i].skipped = 2;
            p = *end == ',' ? end + 1 : end;
        }
    }
    GetModuleFileNameA(NULL, exe, sizeof(exe));
    strcpy(path, exe);
    if ((dot = strrchr(path, '.')) && !strchr(dot, '\\')) *dot = 0;
    strcat(path, ".log");
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: %s, %lu seconds\n", exe, seconds);
    probe_log("machine: built for %s\n",
#if defined(__aarch64__)
              "ARM64"
#elif defined(__x86_64__)
              "x86-64"
#else
              "?"
#endif
    );
    if (IsWow64Process2(GetCurrentProcess(), &process, &native))
        probe_log("machine: IsWow64Process2 process %#x native %#x\n", process, native);

    if (!window_step(inst)) step = 2;
    else if (!dxgi_step()) step = 3;
    else if (!device_step()) step = 4;
    else if (!swap_step()) step = 5;
    else if (!pipeline_step()) step = 6;
    else if (!textures_step()) step = 9;
    else if (!frames_step(seconds)) step = 7;
    else if (!pixels_step()) step = 8;

    if (step) {
        static const char *const names[] = { "", "", "window", "DXGI", "device", "swap chain", "pipeline", "a frame",
                                             "the pixels", "the textures" };
        probe_log("done FAIL at %s\n", names[step]);
    } else {
        probe_log("done ok\n");
    }
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return step;
}

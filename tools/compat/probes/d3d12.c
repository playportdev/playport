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
 *   frames   for 5 seconds (`seconds N` on the command line for N): clear
 *            to dark blue, draw a red-green-blue triangle, present with
 *            sync interval 1, wait for the frame's fence
 *   readback the last frame's back buffer copied to a readback buffer: a
 *            corner pixel must be the clear colour and the centre pixel the
 *            triangle's (not the clear colour, not black)
 *
 * Each line goes to OutputDebugString and <dir>\<exe name>.log, with the
 * DLLs d3d12, d3d12core, dxgi, vulkan-1 and winevulkan resolved from (which
 * file the farm linked). The last line is "d3d12: done ok" and the exit code
 * 0, or "d3d12: done FAIL at <step>" and the step's code: 2 window, 3 DXGI,
 * 4 device, 5 swap chain, 6 pipeline, 7 a frame, 8 the pixels.
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
    ID3D12Resource_Unmap(g.readback, 0, &none);
    probe_log("CHECK the corner is the clear colour and the centre the triangle's: %s\n", ok ? "ok" : "FAIL");
    return ok;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char exe[MAX_PATH], path[MAX_PATH + 8], *dot;
    DWORD seconds = 5;
    USHORT process = 0, native = 0;
    int step = 0;

    if (!strncmp(cmdline, "seconds ", 8)) seconds = strtoul(cmdline + 8, NULL, 0);
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
    else if (!frames_step(seconds)) step = 7;
    else if (!pixels_step()) step = 8;

    if (step) {
        static const char *const names[] = { "", "", "window", "DXGI", "device", "swap chain", "pipeline", "a frame", "the pixels" };
        probe_log("done FAIL at %s\n", names[step]);
    } else {
        probe_log("done ok\n");
    }
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return step;
}

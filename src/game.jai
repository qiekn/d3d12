// D3D12 Minimal Example
// MIT License

#import "Basic";
#import "Windows";
#import "dxgi";
#import "d3d12"()(INCLUDE_DEBUG_BINDINGS = true);
#import "d3d_compiler";

Window :: #import "Window_Creation";
Input  :: #import "Input";

// you can use any window module just we need the hwnd and window width/height
w_hwnd  : HWND;
w_width :u32 = 1200;
w_height:u32 = 800;

main :: () {
    w_hwnd = Window.create_window(w_width, w_height, "ck: Hello Sailor");

    init_backend();
    init_device();
    init_render_context();
    init_pipeline();
    init_command_encoder();

    quit := false;
    while !quit { 
        Input.update_window_events();
        for Input.events_this_frame {
            if it.type == {
                case .QUIT; quit = true;
                case .KEYBOARD;
                    if !it.key_pressed continue;
                    if it.key_code == .ESCAPE then quit = true;
            }
        }

        draw_one_frame();
    }

    queue_wait_idle();
    deinit_command_encoder();
    deinit_pipeline();
    deinit_render_context();
    deinit_device();
    deinit_backend();
}


draw_one_frame :: () {
    // wait for the active frame
    {
        // here we do not want the wait value for last submited frame, we want
        // to wait for the active/current/acquired frame (which in use) last submission.
        wait_value: u64;
        if submit_counter < FRAME_COUNT {
            wait_value = 0;
        } else {
            wait_value = (submit_counter - FRAME_COUNT) + 1;
        }
        // print("frame:% backbuffer:% submit_counter:% checking:% next-check:% \n", active_frame_index, ctx_active_buffer_index, submit_counter, wait_value, submit_counter+1);
        // wait on the host
        if ID3D12Fence_GetCompletedValue(d3d12_submit_fence) < wait_value {
            ID3D12Fence_SetEventOnCompletion(d3d12_submit_fence, wait_value, d3d12_submit_event);
            WaitForSingleObject(d3d12_submit_event, 0xffff_ffff);
        }
    }

    //-------------------

    result: HRESULT;
    cmd_list := d3d12_command_lists[active_frame_index];

    result = ID3D12GraphicsCommandList_Reset(cmd_list, d3d12_command_allocator, d3d12_pipeline_state);
    #if DEBUG assert(S_OK == result);
    {
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(cmd_list, d3d12_root_signature);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology  (cmd_list, .TRIANGLELIST);

        viewport: D3D12_VIEWPORT;
        viewport.TopLeftX = 0.0;
        viewport.TopLeftY = 0.0;
        viewport.Width    = xx w_width;
        viewport.Height   = xx w_height;
        viewport.MinDepth = 0.0;
        viewport.MaxDepth = 1.0; 
        ID3D12GraphicsCommandList_RSSetViewports(cmd_list, 1, *viewport); 

        surface_size: D3D12_RECT;
        surface_size.left = 0;
        surface_size.top  =  0;
        surface_size.right = xx w_width;
        surface_size.bottom = xx w_height;
        ID3D12GraphicsCommandList_RSSetScissorRects(cmd_list, 1, *surface_size);

        // Indicate that the back buffer will be used as a render target. (begin_renderpass)
        rt_barrier: D3D12_RESOURCE_BARRIER;
        rt_barrier.Type                   = .TRANSITION;
        rt_barrier.Flags                  = .NONE;
        rt_barrier.Transition.pResource   = d3d12_rtvs[ctx_active_buffer_index];
        rt_barrier.Transition.StateBefore = .PRESENT;
        rt_barrier.Transition.StateAfter  = .RENDER_TARGET;
        rt_barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        ID3D12GraphicsCommandList_ResourceBarrier(cmd_list, 1, *rt_barrier);

        rtv_handle: D3D12_CPU_DESCRIPTOR_HANDLE = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(d3d12_rtv_heap);
        rtv_handle.ptr = rtv_handle.ptr + (ctx_active_buffer_index * d3d12_rtv_heap_inc_size);
        ID3D12GraphicsCommandList_OMSetRenderTargets(cmd_list, 1, *rtv_handle, .FALSE, null);

        clear_color := float.[0.02, 0.15, 0.15, 1.0];
        ID3D12GraphicsCommandList_ClearRenderTargetView(cmd_list, rtv_handle, *clear_color, 0, null);

        // Draw
        ID3D12GraphicsCommandList_DrawInstanced(cmd_list, 3, 1, 0, 0);

        // Indicate that the back buffer will be used to present. (end_renderpass)
        present_barrier: D3D12_RESOURCE_BARRIER;
        present_barrier.Type                   = .TRANSITION;
        present_barrier.Flags                  = .NONE;
        present_barrier.Transition.pResource   = d3d12_rtvs[ctx_active_buffer_index];
        present_barrier.Transition.StateBefore = .RENDER_TARGET;
        present_barrier.Transition.StateAfter  = .PRESENT;
        present_barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        ID3D12GraphicsCommandList_ResourceBarrier(cmd_list, 1, *present_barrier);
    }
    result = ID3D12GraphicsCommandList_Close(cmd_list);
    #if DEBUG assert(S_OK == result);

    //-------------------

    // Submit
    {
        submit_counter += 1; // increment submission counte
        // Execute the command list.
        ID3D12CommandQueue_ExecuteCommandLists(d3d12_queue, 1, xx *d3d12_command_lists[active_frame_index]);
        // Signal and increment the fence value.
        ID3D12CommandQueue_Signal(d3d12_queue, d3d12_submit_fence, submit_counter);
        // move to next frame
        active_frame_index = (active_frame_index+1) % FRAME_COUNT;
    }

    render_context_present();
}


// ----------------------------------------------------------------------------: Constants

DEBUG          :: true;
ASSERT_ON_FAIL :: true;
BREAK_ON_ERROR :: false;
FRAME_COUNT    :u32: 2;


// ----------------------------------------------------------------------------: Backend : IDXGIFactory4, IDXGIAdapter1

d3d12_factory: *IDXGIFactory4;
d3d12_adapter: *IDXGIAdapter1;

init_backend :: () -> bool {
    log("init_backend...");
    result: HRESULT;
    dxgi_factory_flags: u32 = 0;
    
    #if DEBUG {
        // Enable the debug layer (requires the Graphics Tools "optional feature").
        // For Windows 10, to create a device that supports the debug layer,
        // enable the "Graphics Tools" optional feature. Go to the Settings panel,
        // under System, Apps & features, Manage optional Features, Add a feature,
        // and then look for "Graphics Tools".
        // NOTE: Enabling the debug layer after device creation will invalidate the active device.
        debug_interface: *ID3D12Debug1;
        if SUCCEEDED(D3D12GetDebugInterface(*uid(ID3D12Debug1_UUID), xx *debug_interface)) {
            ID3D12Debug1_EnableDebugLayer(debug_interface);
            // ID3D12Debug1_SetEnableGPUBasedValidation(debug_interface, .TRUE);
            // ID3D12Debug1_SetEnableSynchronizedCommandQueueValidation(debug_interface, .TRUE);
            dxgi_factory_flags |= DXGI_CREATE_FACTORY_DEBUG;
        }
    }
    
    // Cretae Factory
    result = CreateDXGIFactory2(dxgi_factory_flags, *uid(IDXGIFactory4_UUID), xx *d3d12_factory);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "CreateDXGIFactory2 failed.");
        deinit_backend();
        return false;
    }

    // Get Harwere Adapter
    warp_adapter_found := false;

    // first check warp adapter
    // https://docs.microsoft.com/en-us/windows/win32/direct3darticles/directx-warp

    result = IDXGIFactory4_EnumWarpAdapter(d3d12_factory, *uid(IDXGIAdapter1_UUID), xx *d3d12_adapter);
    if S_OK == result {
        // Check to see whether the adapter supports Direct3D 12, but don't create the
        // actual device yet.
        result = D3D12CreateDevice(d3d12_adapter, .D3D_FEATURE_LEVEL_12_0, *uid(ID3D12Device_UUID), null);
        // If ppDevice is NULL and the function succeeds, S_FALSE (0x1) is returned, rather than S_OK.
        if result == 0x1 {
            warp_adapter_found = true;
        } 
    } else {
        if d3d12_adapter IUnknown_Release(d3d12_adapter);
        d3d12_adapter = null;
    }

    adapter_index :u32= 0;
    while true && !warp_adapter_found{
        // print("checking: % adapter_index\n", adapter_index);
        if SUCCEEDED(IDXGIFactory1_EnumAdapters1(d3d12_factory, adapter_index, *d3d12_adapter)) {
            // print("found\n");
            desc:DXGI_ADAPTER_DESC1;
            IDXGIAdapter1_GetDesc1(d3d12_adapter, *desc); 
            // print("desc: %\n", desc);
            // Don't select the Basic Render Driver adapter.
            if (desc.Flags & cast(u32) DXGI_ADAPTER_FLAG.SOFTWARE) continue;
            // Check to see whether the adapter supports Direct3D 12, but don't create the
            // actual device yet.
            result = D3D12CreateDevice(d3d12_adapter, .D3D_FEATURE_LEVEL_12_0, *uid(ID3D12Device_UUID), null);
            // If ppDevice is NULL and the function succeeds, S_FALSE (0x1) is returned, rather than S_OK.
            if 0x1 == result then break;
        }
        // Else we won't use this iteration's adapter, so release it
        IUnknown_Release(d3d12_adapter);
        d3d12_adapter = null;
        adapter_index += 1;
    }

    if !d3d12_adapter {
        #if ASSERT_ON_FAIL assert(false, "Obtaining IDXGIAdapter1 failed.");
        deinit_backend();
        return false;
    } 

    log("init_backend... done");
    return true;
}

deinit_backend :: () {
    log("deinit_backend");
    if d3d12_factory IUnknown_Release(d3d12_factory);
    if d3d12_adapter IUnknown_Release(d3d12_adapter);
}

// ----------------------------------------------------------------------------: Device : ID3D12Device, ID3D12CommandQueue, ID3D12InfoQueue

d3d12_device    : *ID3D12Device;
d3d12_queue     : *ID3D12CommandQueue;
d3d12_info_queue: *ID3D12InfoQueue;
d3d12_queue_wi_fence: *ID3D12Fence;
d3d12_queue_wi_event: *void;

init_device :: () -> bool {
    log("init_device...");
    // Create Device
    result := D3D12CreateDevice(d3d12_adapter, .D3D_FEATURE_LEVEL_12_0, *uid(ID3D12Device_UUID), xx *d3d12_device);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "D3D12CreateDevice failed.");
        deinit_device();
        return false;
    }

    #if DEBUG {
        if SUCCEEDED(IUnknown_QueryInterface(d3d12_device, *uid(ID3D12InfoQueue_UUID), xx *d3d12_info_queue)) {
            //  break (while running the .exe in VS)
            #if BREAK_ON_ERROR {
                ID3D12InfoQueue_SetBreakOnSeverity(d3d12_info_queue, .CORRUPTION, .TRUE);
                ID3D12InfoQueue_SetBreakOnSeverity(d3d12_info_queue, .ERROR, .TRUE);
            }
            // ID3D12InfoQueue_SetBreakOnSeverity(d3d12_info_queue, .D3D12_MESSAGE_SEVERITY_WARNING, .TRUE);
            // ID3D12InfoQueue_SetBreakOnSeverity(d3d12_info_queue, .D3D12_MESSAGE_SEVERITY_INFO, .TRUE);
            // ID3D12InfoQueue_SetBreakOnSeverity(d3d12_info_queue, .D3D12_MESSAGE_SEVERITY_MESSAGE, .TRUE);

            //  setup
            size := ID3D12InfoQueue_GetStorageFilterStackSize(d3d12_info_queue);
            while size > 1 {
                ID3D12InfoQueue_ClearStorageFilter(d3d12_info_queue);
                size = ID3D12InfoQueue_GetStorageFilterStackSize(d3d12_info_queue);
            }

            size = ID3D12InfoQueue_GetRetrievalFilterStackSize(d3d12_info_queue);
            while size > 1 {
                ID3D12InfoQueue_ClearRetrievalFilter(d3d12_info_queue);
                size = ID3D12InfoQueue_GetRetrievalFilterStackSize(d3d12_info_queue);
            }

            ID3D12InfoQueue_ClearStoredMessages(d3d12_info_queue);
            ID3D12InfoQueue_SetMuteDebugOutput(d3d12_info_queue, .FALSE);
        } else {
            log_error("d3d12_device.QueryInterface faild.");
        }
    }

    // Describe and create the command queue.
    queue_desc: D3D12_COMMAND_QUEUE_DESC;
    queue_desc.Flags = .NONE;
    queue_desc.Type  = .DIRECT;
    result = ID3D12Device_CreateCommandQueue(d3d12_device, *queue_desc, *uid(ID3D12CommandQueue_UUID), xx *d3d12_queue);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateCommandQueue failed.");
        deinit_device();
        return false;
    }

    // Wait idle fence
    result = ID3D12Device_CreateFence(d3d12_device, 0, .NONE, *uid(ID3D12Fence_UUID), xx *d3d12_queue_wi_fence);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateFence failed.");
        deinit_device();
        return false;
    }

    // Create an event handle.
    d3d12_queue_wi_event = CreateEventW(null, 0, 0, null);
    if d3d12_queue_wi_event == null {
        #if ASSERT_ON_FAIL assert(false, "CreateEventW failed.");
        deinit_device();
        return false;
    }

    log("init_device... done");
    return true;
}

// call queue_wait_idle before deinit
deinit_device :: () {
    log("deinit_device");
    if d3d12_queue IUnknown_Release(d3d12_queue);
    if d3d12_queue_wi_fence IUnknown_Release(d3d12_queue_wi_fence);
    if d3d12_queue_wi_event CloseHandle(d3d12_queue_wi_event);
    #if DEBUG {
        if d3d12_device {
            debug_device: *ID3D12DebugDevice;
            ok := IUnknown_QueryInterface(d3d12_device, *uid(ID3D12DebugDevice_UUID), xx *debug_device);
            IUnknown_Release(d3d12_device);
            if ok == S_OK {
                ID3D12DebugDevice_ReportLiveDeviceObjects(debug_device, D3D12_RLDO_FLAGS.DETAIL | .IGNORE_INTERNAL);
                IUnknown_Release(debug_device);
                print_debug_msgs(d3d12_info_queue);
            }
        }
    } else {
        if d3d12_device  IUnknown_Release(xx d3d12_device);
    }
    if d3d12_info_queue  IUnknown_Release(d3d12_info_queue);
}

// wait on the host for the GPU, for all of queue operations.
queue_wait_idle :: () {
    value: u64 = ID3D12Fence_GetCompletedValue(d3d12_queue_wi_fence);
    signal_value := value + 10;
    // signal for the GPU
    ID3D12CommandQueue_Signal(d3d12_queue, d3d12_queue_wi_fence, signal_value);
    // wait on the host
    if ID3D12Fence_GetCompletedValue(d3d12_queue_wi_fence) < signal_value {
        ID3D12Fence_SetEventOnCompletion(d3d12_queue_wi_fence, signal_value, d3d12_queue_wi_event);
        WaitForSingleObject(d3d12_queue_wi_event, 0xffff_ffff);
    }
}

// ----------------------------------------------------------------------------: Render Context: IDXGISwapChain3, ID3D12Resource, ID3D12DescriptorHeap

VSYNC :: false;
MAX_SWAPCHAIN_BUFFER_COUNT :: 3;

d3d12_swapchain    : *IDXGISwapChain3;
d3d12_rtvs         : [MAX_SWAPCHAIN_BUFFER_COUNT] *ID3D12Resource;
d3d12_rtv_heap     : *ID3D12DescriptorHeap;
d3d12_rtv_heap_inc_size: u32;
d3d12_present_fence: *ID3D12Fence;
d3d12_present_event: *void;

ctx_buffer_count       : u32;  // use this to get actual count.
ctx_active_buffer_index: u32;
ctx_present_counter    : u64;

init_render_context :: () -> bool {
    log("init_render_context...");
    // SEE: https://devblogs.microsoft.com/directx/dxgi-flip-model/
    // SEE: https://docs.microsoft.com/en-us/windows/win32/api/dxgi/ne-dxgi-dxgi_swap_effect
    // Describe and create the swap chain.
    if !VSYNC {
        ctx_buffer_count = 3;
    } else {
        ctx_buffer_count = 2; 
    }

    swap_chain_desc: DXGI_SWAP_CHAIN_DESC1;
    swap_chain_desc.BufferCount      = ctx_buffer_count;
    swap_chain_desc.Width            = w_width;
    swap_chain_desc.Height           = w_height;
    swap_chain_desc.Format           = .R8G8B8A8_UNORM;
    swap_chain_desc.BufferUsage      = .RENDER_TARGET_OUTPUT;
    swap_chain_desc.SwapEffect       = .FLIP_SEQUENTIAL;//.FLIP_DISCARD; // NOTE: BufferCount must be > 1 for using "DXGI_SWAP_EFFECT_FLIP_DISCARD/DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL"
    swap_chain_desc.SampleDesc.Count = 1;

    result := IDXGIFactory2_CreateSwapChainForHwnd(d3d12_factory,
        xx d3d12_queue,    // Swapchain needs the queue so that it can force a flush on it.
        w_hwnd,
        *swap_chain_desc,
        null,
        null,
        xx *d3d12_swapchain
        );

    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_factory.CreateSwapChainForHwnd failed.");
        deinit_render_context();
        return false;;
    }

    // This sample does not support fullscreen transitions.
    IDXGIFactory_MakeWindowAssociation(d3d12_factory, w_hwnd, xx DXGI_MWA.NO_ALT_ENTER);

    // Create descriptor heaps.
    {
        // Describe and create a render target view (RTV) descriptor heap.
        rtv_heap_desc: D3D12_DESCRIPTOR_HEAP_DESC;
        rtv_heap_desc.NumDescriptors = ctx_buffer_count;
        rtv_heap_desc.Type  = .RTV;
        rtv_heap_desc.Flags = .NONE;
        result = ID3D12Device_CreateDescriptorHeap(d3d12_device, *rtv_heap_desc, *uid(ID3D12DescriptorHeap_UUID), xx *d3d12_rtv_heap);
        if result != S_OK {
            #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateDescriptorHeap failed.");
            deinit_render_context();
            return false;;
        }
        d3d12_rtv_heap_inc_size = ID3D12Device_GetDescriptorHandleIncrementSize(d3d12_device, .RTV);
    }

    // Create frame resources.
    {
        rtv_handle: D3D12_CPU_DESCRIPTOR_HANDLE = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(d3d12_rtv_heap);
        // Create a RTV for each frame.
        for n:0..ctx_buffer_count-1 {
            result = IDXGISwapChain_GetBuffer(d3d12_swapchain, xx n, *uid(ID3D12Resource_UUID), xx *d3d12_rtvs[n]);
            if result != S_OK {
                #if ASSERT_ON_FAIL assert(false, "d3d12_swapchain.GetBuffer failed.");
                deinit_render_context();
                return false;;
            }

            rtv_desc: D3D12_RENDER_TARGET_VIEW_DESC;
            rtv_desc.ViewDimension = .TEXTURE2D;
            rtv_desc.Format = .R8G8B8A8_UNORM_SRGB;
            ID3D12Device_CreateRenderTargetView(d3d12_device, d3d12_rtvs[n], *rtv_desc, rtv_handle);
            rtv_handle.ptr += (1 * d3d12_rtv_heap_inc_size);
        }
    }

    // set the backbuffer index for next present.
    ctx_active_buffer_index = IDXGISwapChain3_GetCurrentBackBufferIndex(d3d12_swapchain);

    // Present fence
    result = ID3D12Device_CreateFence(d3d12_device, 0, .NONE, *uid(ID3D12Fence_UUID), xx *d3d12_present_fence);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateFence failed.");
        deinit_render_context();
        return false;
    }

    // Create an event handle.
    d3d12_present_event = CreateEventW(null, 0, 0, null);
    if d3d12_present_event == null {
        #if ASSERT_ON_FAIL assert(false, "CreateEventW failed.");
        deinit_render_context();
        return false;
    }

    log("init_render_context... done");
    return true;
}

deinit_render_context :: () {
    log("deinit_render_context");
    if d3d12_swapchain IUnknown_Release(d3d12_swapchain);
    if d3d12_rtv_heap  IUnknown_Release(d3d12_rtv_heap);
    for 0..ctx_buffer_count-1 {
        if d3d12_rtvs[it] IUnknown_Release(d3d12_rtvs[it]);
    }
    if d3d12_present_fence IUnknown_Release(d3d12_present_fence);
    if d3d12_present_event CloseHandle(d3d12_present_event);
}

render_context_present :: () {
    // Increment and signal the fence value. (from the gpu to the cpu)
    // to know if the all commands executed.
    ctx_present_counter += 1;
    ID3D12CommandQueue_Signal(d3d12_queue, d3d12_present_fence, ctx_present_counter);
    // wait for the gpu "wait for commands execution"
    if ID3D12Fence_GetCompletedValue(d3d12_present_fence) < ctx_present_counter {
        ID3D12Fence_SetEventOnCompletion(d3d12_present_fence, ctx_present_counter, d3d12_present_event);
        WaitForSingleObject(d3d12_present_event, 0xffff_ffff);
    }
    hr: HRESULT;
    if VSYNC {
        hr = IDXGISwapChain_Present(xx d3d12_swapchain, 1, 0);
    } else {
        hr = IDXGISwapChain_Present(xx d3d12_swapchain, 0, 0);
    }
    #if DEBUG assert(hr == S_OK);
    
    ctx_active_buffer_index = IDXGISwapChain3_GetCurrentBackBufferIndex(d3d12_swapchain);
}

// ----------------------------------------------------------------------------: Pipeline

d3d12_root_signature: *ID3D12RootSignature;
d3d12_pipeline_state: *ID3D12PipelineState;

init_pipeline :: () -> bool {
    log("init_pipeline...");
    // Create an empty root signature.
    // NOTE: see https://alain.xyz/blog/raw-directx12 if you want to use Root Signature Version 1.1
    root_signature_desc: D3D12_ROOT_SIGNATURE_DESC;
    root_signature_desc.NumParameters = 0;
    root_signature_desc.pParameters = null;
    root_signature_desc.NumStaticSamplers = 0;
    root_signature_desc.pStaticSamplers = null;
    //root_signature_desc.Flags = .D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT; Since we do not use vertex buffer
    signature: *ID3DBlob;
    error: *ID3DBlob;
    result := D3D12SerializeRootSignature(*root_signature_desc, .D3D_ROOT_SIGNATURE_VERSION_1,  *signature, *error);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "D3D12SerializeRootSignature failed.");
        deinit_pipeline();
        return false;
    }
    result = ID3D12Device_CreateRootSignature(d3d12_device, 0,
     ID3D10Blob_GetBufferPointer(signature),
     ID3D10Blob_GetBufferSize(signature), 
     *uid(ID3D12RootSignature_UUID), xx *d3d12_root_signature);

    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateRootSignature failed.");
        deinit_pipeline();
        return false;
    }

    // Create pipeline state
    de: D3D12_GRAPHICS_PIPELINE_STATE_DESC;
    // RootSignature (pipeline layout)
    de.pRootSignature = d3d12_root_signature;

    // Vertex Shader
    vs_bytecode, vs_success := compile_shader(SHADER_TEXT, "VSMain", "vs_5_0");
    #if DEBUG assert(vs_success, "compile_shader faild VS.");
    defer free(vs_bytecode);
    de.VS.pShaderBytecode = vs_bytecode.data;
    de.VS.BytecodeLength  = xx vs_bytecode.count;
    // Pixel Shader
    ps_bytecode, ps_success := compile_shader(SHADER_TEXT, "PSMain", "ps_5_0");
    #if DEBUG assert(ps_success, "compile_shader failed FS.");
    defer free(ps_bytecode);
    de.PS.pShaderBytecode = ps_bytecode.data;
    de.PS.BytecodeLength  = xx ps_bytecode.count;
    
    // Vertex inlput layout
    de.InputLayout.pInputElementDescs = null;
    de.InputLayout.NumElements        = 0;

    // Primitive Topology Type
    de.PrimitiveTopologyType = .TRIANGLE;
    de.IBStripCutValue       = .DISABLED;

    // Blend State
    de.BlendState.AlphaToCoverageEnable  = .FALSE; // @Multisample related
    de.BlendState.IndependentBlendEnable = .FALSE;
    for i: 0..7 {
        de.BlendState.RenderTarget[i].LogicOpEnable  = .FALSE;
        de.BlendState.RenderTarget[i].LogicOp        = .CLEAR; // .NOOP;
        de.BlendState.RenderTarget[i].BlendEnable    = .FALSE;
        de.BlendState.RenderTarget[i].SrcBlend       = .ONE;
        de.BlendState.RenderTarget[i].DestBlend      = .ZERO;
        de.BlendState.RenderTarget[i].BlendOp        = .ADD;
        de.BlendState.RenderTarget[i].SrcBlendAlpha  = .ONE;
        de.BlendState.RenderTarget[i].DestBlendAlpha = .ZERO;
        de.BlendState.RenderTarget[i].BlendOpAlpha   = .ADD;
        de.BlendState.RenderTarget[i].RenderTargetWriteMask = cast(u8) D3D12_COLOR_WRITE_ENABLE.ALL; 
    }

    // Rasterizer State
    de.RasterizerState.FillMode              = .SOLID;
    de.RasterizerState.CullMode              = .BACK;
    de.RasterizerState.FrontCounterClockwise = .FALSE;
    de.RasterizerState.DepthClipEnable       = .FALSE;
    de.RasterizerState.DepthBias             = D3D12_DEFAULT_DEPTH_BIAS;
    de.RasterizerState.DepthBiasClamp        = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
    de.RasterizerState.SlopeScaledDepthBias  = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
    de.RasterizerState.AntialiasedLineEnable = .FALSE;
    de.RasterizerState.MultisampleEnable     = .FALSE; // @Multisample related

    // @Multisample related
    de.SampleDesc.Count   = 1;
    de.SampleDesc.Quality = 0;
    de.SampleMask = 0xffff_ffff;

    // Depth Stencil State
    // depth
    de.DepthStencilState.DepthEnable    = .FALSE;
    // de.DepthStencilState.DepthWriteMask = .ALL;
    // de.DepthStencilState.DepthFunc      = .NEVER;
    // stencil
    de.DepthStencilState.StencilEnable  = .FALSE;
    // de.DepthStencilState.FrontFace.StencilFailOp      = ;
    // de.DepthStencilState.FrontFace.StencilPassOp      = ;
    // de.DepthStencilState.FrontFace.StencilDepthFailOp = ;
    // de.DepthStencilState.FrontFace.StencilFunc        = .NEVER;
    // de.DepthStencilState.BackFace.StencilFailOp       = ;
    // de.DepthStencilState.BackFace.StencilPassOp       = ;
    // de.DepthStencilState.BackFace.StencilDepthFailOp  = ;
    // de.DepthStencilState.BackFace.StencilFunc         = .NEVER;
    // de.DepthStencilState.StencilReadMask              = 0xff; 
    // de.DepthStencilState.StencilWriteMask             = 0xff;
    
    // Output
    de.NumRenderTargets = 1;
    de.RTVFormats[0]    = .R8G8B8A8_UNORM_SRGB;

    result = ID3D12Device_CreateGraphicsPipelineState(d3d12_device, *de, *uid(ID3D12PipelineState_UUID), xx *d3d12_pipeline_state);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateGraphicsPipelineState failed.");
        deinit_pipeline();
        return false;
    }

    log("init_pipeline... done");
    return true;
}

deinit_pipeline :: () {
    log("deinit_pipeline");
    if d3d12_pipeline_state IUnknown_Release(d3d12_pipeline_state);
    if d3d12_root_signature IUnknown_Release(d3d12_root_signature);
}


// ----------------------------------------------------------------------------: Command Encoder: ID3D12CommandAllocator, ID3D12GraphicsCommandList

d3d12_command_allocator: *ID3D12CommandAllocator;
d3d12_command_lists    : [FRAME_COUNT] *ID3D12GraphicsCommandList;
d3d12_submit_fence     : *ID3D12Fence;
d3d12_submit_event     : *void;

active_frame_index: u32; 
submit_counter    : u64;

init_command_encoder :: () -> bool {
    log("init_command_encoder...");
    // create command allocator
    result := ID3D12Device_CreateCommandAllocator(d3d12_device, .DIRECT, *uid(ID3D12CommandAllocator_UUID), xx *d3d12_command_allocator);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateCommandAllocator failed.");
        deinit_command_encoder();
        return false;
    }

    // Create the command lists.
    for i: 0..FRAME_COUNT-1 {
        result = ID3D12Device_CreateCommandList(d3d12_device, 0, .DIRECT, d3d12_command_allocator, null, *uid(ID3D12GraphicsCommandList_UUID), xx *d3d12_command_lists[i]);
        if result != S_OK {
            #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateCommandList failed.");
            deinit_command_encoder();
            return false;
        }
        // Command lists are created in the recording state, but there is nothing
        // to record yet. The main loop expects it to be closed, so close it now.
        ID3D12GraphicsCommandList_Close(d3d12_command_lists[i]);
    }

    // Submit fence
    result = ID3D12Device_CreateFence(d3d12_device, 0, .NONE, *uid(ID3D12Fence_UUID), xx *d3d12_submit_fence);
    if result != S_OK {
        #if ASSERT_ON_FAIL assert(false, "d3d12_device.CreateFence failed.");
        deinit_render_context();
        return false;
    }

    // Create an event handle.
    d3d12_submit_event = CreateEventW(null, 0, 0, null);
    if d3d12_submit_event == null {
        #if ASSERT_ON_FAIL assert(false, "CreateEventW failed.");
        deinit_render_context();
        return false;
    }

    log("init_command_encoder...done");
    return true;
}

deinit_command_encoder :: () {
    log("deinit_command_encoder");
    if d3d12_command_allocator ID3D12CommandAllocator_Reset(d3d12_command_allocator);
    for i: 0..FRAME_COUNT-1 {
        if d3d12_command_lists[i] IUnknown_Release(d3d12_command_lists[i]);
    }
    if d3d12_command_allocator IUnknown_Release(d3d12_command_allocator);
    if d3d12_submit_fence IUnknown_Release(d3d12_submit_fence);
    if d3d12_submit_event CloseHandle(d3d12_submit_event);
}


// ----------------------------------------------------------------------------: Utils

print_debug_msgs :: (d3d12_info_queue:*ID3D12InfoQueue) {
    if !d3d12_info_queue return;
    msgs_count := ID3D12InfoQueue_GetNumStoredMessages(d3d12_info_queue);
    // print("msgs_count: %\n", msgs_count);
    if msgs_count == 0 return;

    for 0..msgs_count-1 {
        size: u64;
        result := ID3D12InfoQueue_GetMessageA(d3d12_info_queue, it, null, *size);

        // WARNING: This is dummy you should never alloc and free for each msg, but this just an example
        // You shall find better way.
        msg: *D3D12_MESSAGE = xx alloc(xx size);
        defer free(msg);
        result = ID3D12InfoQueue_GetMessageA(d3d12_info_queue, it, msg, *size);

        str: string;
        str.data  = msg.pDescription;
        str.count = xx msg.DescriptionByteLength;

        prefix: string;
        if  msg.Severity == {
            case .CORRUPTION; prefix = "CORRUPTION";
            case .ERROR;      prefix = "ERROR";
            case .WARNING;    prefix = "WARNING";
            case .INFO;       prefix = "INFO";
            case .MESSAGE;    prefix = "MESSAGE";
        }

        category: string;
        if  msg.Category == {
            case .APPLICATION_DEFINED;   category = "APPLICATION_DEFINED";
            case .MISCELLANEOUS;         category = "MISCELLANEOUS";
            case .INITIALIZATION;        category = "INITIALIZATION";
            case .CLEANUP;               category = "CLEANUP";
            case .COMPILATION;           category = "COMPILATION";
            case .STATE_CREATION;        category = "STATE_CREATION";
            case .STATE_SETTING;         category = "STATE_SETTING";
            case .STATE_GETTING;         category = "STATE_GETTING";
            case .RESOURCE_MANIPULATION; category = "RESOURCE_MANIPULATION";
            case .EXECUTION;             category = "EXECUTION";
            case .SHADER;                category = "SHADER";
        }

        print("[D3D12][%]:% - %, \n", prefix, category, msg.ID);
        print("%\n", str);
    }

    ID3D12InfoQueue_ClearStoredMessages(d3d12_info_queue);
}


compile_shader :: (source: string, entry_point: string, shader_model: string) -> string, bool {
    flags := D3DCOMPILE.ENABLE_STRICTNESS; 
    #if DEBUG {
        // Set the D3DCOMPILE_DEBUG flag to embed debug information in the shaders. 
        // Setting this flag improves the shader debugging experience, but still allows  
        // the shaders to be optimized and to run exactly the way they will run in  
        // the release configuration of this program. 
        flags |= .DEBUG; 
        // Disable optimizations to further improve shader debugging 
        flags |= .SKIP_OPTIMIZATION; 
    }
    defines: [] string;
    bytecode, errors, hr := D3DCompile(source, "source", defines, null, entry_point, shader_model, xx flags, 0);
    defer free(errors);

    if FAILED(hr) { 
        free(bytecode);
        if errors log_error("compile_shader: Error msg: %", errors);
        return "", false;
    } 
    return bytecode, true;
}


// ----------------------------------------------------------------------------: Shaders

SHADER_TEXT :: #string END
struct PSInput
{
    float4 position : SV_POSITION;
    float4 color    : COLOR;
};

static float2 positions[3] = {
    float2(0.0, 0.5),
    float2(0.5, -0.5),
    float2(-0.5, -0.5)
};

static float3 colors[3] = {
    float3(1.0, 0.0, 0.0),
    float3(0.0, 1.0, 0.0),
    float3(0.0, 0.0, 1.0)
};


PSInput VSMain(uint vertex_id: SV_VERTEXID)
{
    PSInput result;
    result.position = float4(positions[vertex_id], 0.0, 1.0);
    result.color    = float4(colors[vertex_id], 1.0);

    return result;
}

float4 PSMain(PSInput input) : SV_TARGET
{
    return input.color;
}
END;

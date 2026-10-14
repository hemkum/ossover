// SPDX-License-Identifier: GPL-3.0-or-later
// d3d11present: a minimal presenting Direct3D 11 program for exercising the swap chain and the
// Metal Performance HUD inside a bottle.
//
// Creates a 640x360 (client area) overlapped window, a hardware D3D11 device and a DXGI swap
// chain on it through IDXGIFactory1::CreateSwapChain (R8G8B8A8_UNORM; flip-discard first, the
// blit DISCARD model as fallback), then for N seconds (argv[1], default 10) clears the back
// buffer to a slowly cycling colour and Presents with vsync interval 1 while pumping the message
// loop. Prints "frames=<n> seconds=<s>" and exits 0; exits 1 with the failing HRESULT otherwise.
// Closing the window ends the loop early (still exit 0).
//
// Build: scripts/probes/build.sh (x86_64-w64-mingw32-gcc).

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>

static const char *const window_class = "ossover_d3d11present";

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    if (msg == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wparam, lparam);
}

/* Pumps every pending message; returns 0 once WM_QUIT has been seen. */
static int pump_messages(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return 1;
}

static HWND create_window(int width, int height)
{
    WNDCLASSA wc = {0};
    RECT rect = { 0, 0, width, height };
    DWORD style = WS_OVERLAPPEDWINDOW;
    HWND hwnd;

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = window_class;
    if (!RegisterClassA(&wc)) return NULL;

    AdjustWindowRect(&rect, style, FALSE);
    hwnd = CreateWindowExA(0, window_class, "ossover d3d11present", style, CW_USEDEFAULT, CW_USEDEFAULT,
                           rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) return NULL;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    return hwnd;
}

/* Triangle wave in [0, 1] with period `period` steps, offset by `phase` steps. */
static float wave(unsigned step, unsigned period, unsigned phase)
{
    unsigned t = (step + phase) % period;
    unsigned half = period / 2;
    return (t < half ? t : period - t) / (float)half;
}

int main(int argc, char **argv)
{
    static const D3D_FEATURE_LEVEL wanted[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    const int width = 640, height = 360;
    double seconds = 10;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory1 *factory = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    DXGI_SWAP_CHAIN_DESC sd = {0};
    DXGI_ADAPTER_DESC desc;
    char description[128];
    const char *effect_name = "flip-discard";
    D3D_FEATURE_LEVEL level = 0;
    LARGE_INTEGER freq, start, now;
    HRESULT hr;
    HWND hwnd;
    unsigned frames = 0;
    double elapsed = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1) {
        seconds = atof(argv[1]);
        if (seconds <= 0) seconds = 10;
    }

    hwnd = create_window(width, height);
    if (!hwnd) {
        printf("PRESENT FAIL CreateWindow error=%lu\n", (unsigned long)GetLastError());
        return 1;
    }
    pump_messages();

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, wanted, 2, D3D11_SDK_VERSION,
                           &device, &level, &context);
    if (FAILED(hr)) {
        printf("PRESENT FAIL D3D11CreateDevice hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }

    hr = ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device);
    if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory1, (void **)&factory);
    if (FAILED(hr)) {
        printf("PRESENT FAIL factory query hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc))) {
        WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, description, sizeof description, NULL, NULL);
        printf("D3D11 OK level=0x%x adapter=%s\n", level, description);
    }

    sd.BufferDesc.Width = width;
    sd.BufferDesc.Height = height;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.OutputWindow = hwnd;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = IDXGIFactory1_CreateSwapChain(factory, (IUnknown *)device, &sd, &swapchain);
    if (FAILED(hr)) {
        printf("swapchain flip-discard refused hr=0x%08lx, trying discard\n", (unsigned long)hr);
        sd.BufferCount = 1;
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
        effect_name = "discard";
        hr = IDXGIFactory1_CreateSwapChain(factory, (IUnknown *)device, &sd, &swapchain);
    }
    if (FAILED(hr)) {
        printf("PRESENT FAIL CreateSwapChain hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("swapchain OK effect=%s buffers=%u %dx%d\n", effect_name, sd.BufferCount, width, height);

    hr = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL, &rtv);
    if (FAILED(hr)) {
        printf("PRESENT FAIL back buffer RTV hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }

    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    while (pump_messages()) {
        float colour[4] = { wave(frames, 600, 0), wave(frames, 600, 200), wave(frames, 600, 400), 1.0f };
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(context, rtv, colour);
        hr = IDXGISwapChain_Present(swapchain, 1, 0);
        if (FAILED(hr)) {
            printf("PRESENT FAIL Present hr=0x%08lx after %u frames\n", (unsigned long)hr, frames);
            return 1;
        }
        frames++;
        QueryPerformanceCounter(&now);
        elapsed = (double)(now.QuadPart - start.QuadPart) / (double)freq.QuadPart;
        if (elapsed >= seconds) break;
    }
    printf("frames=%u seconds=%.2f\n", frames, elapsed);

    ID3D11RenderTargetView_Release(rtv);
    ID3D11Texture2D_Release(backbuffer);
    IDXGISwapChain_Release(swapchain);
    IDXGIFactory1_Release(factory);
    IDXGIAdapter_Release(adapter);
    IDXGIDevice_Release(dxgi_device);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    DestroyWindow(hwnd);
    return 0;
}

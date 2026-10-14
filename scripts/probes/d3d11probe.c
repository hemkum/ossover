// SPDX-License-Identifier: GPL-3.0-or-later
// d3d11probe: proves which Direct3D 11 implementation answers inside a bottle.
//
// Creates a hardware D3D11 device (feature level 11_0, falling back to 10_0), reports the
// DXGI adapter the device sits on, then creates and destroys a small texture for two
// seconds so a logging implementation (DXMT with DXMT_LOG_PATH set) has something to say.
// Exit code 0 on success, 1 on failure with the HRESULT printed.
//
// Build: scripts/probes/build.sh (x86_64-w64-mingw32-gcc).

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static void module_path(const char *name)
{
    HMODULE module = GetModuleHandleA(name);
    char path[MAX_PATH] = "(not loaded)";
    if (module) GetModuleFileNameA(module, path, sizeof path);
    printf("module %s -> %s\n", name, path);
}

int main(void)
{
    static const D3D_FEATURE_LEVEL wanted[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    D3D_FEATURE_LEVEL level = 0;
    DXGI_ADAPTER_DESC desc;
    char description[128];
    HRESULT hr;
    DWORD start;
    int created = 0;

    setvbuf(stdout, NULL, _IONBF, 0);

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, wanted, 2, D3D11_SDK_VERSION,
                           &device, &level, &context);
    if (FAILED(hr)) {
        printf("D3D11 FAIL D3D11CreateDevice hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }

    hr = ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device);
    if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetDesc(adapter, &desc);
    if (FAILED(hr)) {
        printf("D3D11 FAIL adapter query level=0x%x hr=0x%08lx\n", level, (unsigned long)hr);
        return 1;
    }
    WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, description, sizeof description, NULL, NULL);
    printf("D3D11 OK level=0x%x adapter=%s vendor=0x%x device=0x%x vram=%luMB\n",
           level, description, desc.VendorId, desc.DeviceId,
           (unsigned long)(desc.DedicatedVideoMemory >> 20));
    module_path("d3d11.dll");
    module_path("dxgi.dll");
    module_path("winemetal.dll");
    module_path("wined3d.dll");

    start = GetTickCount();
    while (GetTickCount() - start < 2000) {
        D3D11_TEXTURE2D_DESC td = {0};
        ID3D11Texture2D *texture = NULL;
        td.Width = 64;
        td.Height = 64;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        hr = ID3D11Device_CreateTexture2D(device, &td, NULL, &texture);
        if (FAILED(hr)) {
            printf("D3D11 FAIL CreateTexture2D hr=0x%08lx after %d textures\n", (unsigned long)hr, created);
            break;
        }
        ID3D11DeviceContext_Flush(context);
        ID3D11Texture2D_Release(texture);
        created++;
        Sleep(10);
    }
    printf("textures created/destroyed: %d\n", created);

    IDXGIAdapter_Release(adapter);
    IDXGIDevice_Release(dxgi_device);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return FAILED(hr) ? 1 : 0;
}

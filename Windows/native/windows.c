#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_6.h>
#include <stdint.h>

struct mpvkit_display_info {
    uint32_t size;
    uint32_t bits_per_color;
    uint32_t color_space;
    uint32_t hdr_active;
    float minimum_luminance;
    float maximum_luminance;
    float maximum_full_frame_luminance;
};

__declspec(dllexport) HRESULT mpvkit_query_display(HWND window, struct mpvkit_display_info *info)
{
    if (!info || info->size != sizeof(*info) || !IsWindow(window))
        return E_INVALIDARG;
    HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
    IDXGIFactory1 *factory = NULL;
    HRESULT status = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    if (FAILED(status))
        return status;
    status = DXGI_ERROR_NOT_FOUND;
    for (UINT adapter_index = 0; ; adapter_index++) {
        IDXGIAdapter1 *adapter = NULL;
        if (IDXGIFactory1_EnumAdapters1(factory, adapter_index, &adapter) == DXGI_ERROR_NOT_FOUND)
            break;
        if (!adapter)
            break;
        for (UINT output_index = 0; ; output_index++) {
            IDXGIOutput *output = NULL;
            if (IDXGIAdapter1_EnumOutputs(adapter, output_index, &output) == DXGI_ERROR_NOT_FOUND)
                break;
            if (!output)
                break;
            DXGI_OUTPUT_DESC description;
            HRESULT query = IDXGIOutput_GetDesc(output, &description);
            if (SUCCEEDED(query) && description.Monitor == monitor) {
                IDXGIOutput6 *advanced = NULL;
                status = IDXGIOutput_QueryInterface(output, &IID_IDXGIOutput6, (void **)&advanced);
                if (SUCCEEDED(status)) {
                    DXGI_OUTPUT_DESC1 hdr;
                    status = IDXGIOutput6_GetDesc1(advanced, &hdr);
                    if (SUCCEEDED(status)) {
                        info->bits_per_color = hdr.BitsPerColor;
                        info->color_space = hdr.ColorSpace;
                        info->hdr_active = hdr.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 && hdr.BitsPerColor >= 10;
                        info->minimum_luminance = hdr.MinLuminance;
                        info->maximum_luminance = hdr.MaxLuminance;
                        info->maximum_full_frame_luminance = hdr.MaxFullFrameLuminance;
                    }
                    IDXGIOutput6_Release(advanced);
                }
                IDXGIOutput_Release(output);
                IDXGIAdapter1_Release(adapter);
                IDXGIFactory1_Release(factory);
                return status;
            }
            IDXGIOutput_Release(output);
        }
        IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    return status;
}

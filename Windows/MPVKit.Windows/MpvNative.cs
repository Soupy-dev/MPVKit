using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MPVKit.Windows;

[StructLayout(LayoutKind.Explicit, Size = 16)]
internal struct MpvNode
{
    [FieldOffset(0)] public nint Pointer;
    [FieldOffset(0)] public long Integer;
    [FieldOffset(0)] public int Flag;
    [FieldOffset(0)] public double Number;
    [FieldOffset(8)] public int Format;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MpvNodeList
{
    public int Count;
    public nint Values;
    public nint Keys;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MpvEvent
{
    public int Id;
    public int Error;
    public ulong UserData;
    public nint Data;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MpvPropertyEvent
{
    public nint Name;
    public int Format;
    public nint Data;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MpvEndEvent
{
    public int Reason;
    public int Error;
    public long EntryId;
    public long InsertId;
    public int InsertCount;
}

internal sealed class MpvArena : IDisposable
{
    private readonly List<nint> allocations = [];

    private nint Allocate(int bytes)
    {
        var pointer = Marshal.AllocHGlobal(bytes);
        allocations.Add(pointer);
        return pointer;
    }

    private nint Utf8(string value)
    {
        if (value.Contains('\0')) throw new ArgumentException("Embedded NUL is not allowed.");
        var pointer = Marshal.StringToCoTaskMemUTF8(value);
        utf8Allocations.Add(pointer);
        return pointer;
    }

    private readonly List<nint> utf8Allocations = [];

    public MpvNode Create(object? value) => CreateNode(JsonSerializer.SerializeToNode(value), 0);

    private MpvNode CreateNode(JsonNode? value, int depth)
    {
        if (depth > 16) throw new ArgumentException("mpv argument nesting exceeds 16 levels.");
        if (value is null) return default;
        if (value is JsonArray array)
            return CreateList(array.Select(v => (Key: (string?)null, Value: v)).ToArray(), false, depth);
        if (value is JsonObject map)
            return CreateList(map.Select(v => (Key: (string?)v.Key, Value: v.Value)).ToArray(), true, depth);
        var scalar = (JsonValue)value;
        if (scalar.TryGetValue<JsonElement>(out var element))
        {
            return element.ValueKind switch
            {
                JsonValueKind.String => new() { Format = 1, Pointer = Utf8(element.GetString()!) },
                JsonValueKind.True => new() { Format = 3, Integer = 1 },
                JsonValueKind.False => new() { Format = 3 },
                JsonValueKind.Number when element.TryGetInt64(out var integer) => new() { Format = 4, Integer = integer },
                JsonValueKind.Number => new() { Format = 5, Number = element.GetDouble() },
                _ => throw new ArgumentException("Unsupported mpv argument.")
            };
        }
        throw new ArgumentException("Unsupported mpv value.");
    }

    private MpvNode CreateList((string? Key, JsonNode? Value)[] entries, bool map, int depth)
    {
        if (entries.Length > 4096) throw new ArgumentException("Too many mpv arguments.");
        var values = Allocate(Math.Max(1, entries.Length * 16));
        var keys = map ? Allocate(Math.Max(1, entries.Length * nint.Size)) : 0;
        for (var index = 0; index < entries.Length; index++)
        {
            Marshal.StructureToPtr(CreateNode(entries[index].Value, depth + 1), values + index * 16, false);
            if (map) Marshal.WriteIntPtr(keys, index * nint.Size, Utf8(entries[index].Key!));
        }
        var list = Allocate(Marshal.SizeOf<MpvNodeList>());
        Marshal.StructureToPtr(new MpvNodeList { Count = entries.Length, Values = values, Keys = keys }, list, false);
        return new() { Format = map ? 8 : 7, Pointer = list };
    }

    public static JsonNode? Read(MpvNode node)
    {
        var budget = 16384;
        var bytes = 4 * 1024 * 1024;
        return ReadNode(node, 0, ref budget, ref bytes);
    }

    private static unsafe string ReadString(nint pointer, ref int bytes)
    {
        if (pointer == 0) return "";
        var span = new ReadOnlySpan<byte>((void*)pointer, bytes + 1);
        var count = span.IndexOf((byte)0);
        if (count < 0) throw new InvalidDataException("mpv response exceeds 4 MiB.");
        bytes -= count;
        return System.Text.Encoding.UTF8.GetString(span[..count]);
    }

    private static JsonNode? ReadNode(MpvNode node, int depth, ref int budget, ref int bytes)
    {
        if (--budget < 0 || depth > 32) throw new InvalidDataException("mpv response exceeds its structural limit.");
        switch (node.Format)
        {
            case 0: return null;
            case 1: return JsonValue.Create(ReadString(node.Pointer, ref bytes));
            case 3: return JsonValue.Create(node.Flag != 0);
            case 4: return JsonValue.Create(node.Integer);
            case 5: return double.IsFinite(node.Number) ? JsonValue.Create(node.Number) : null;
            case 7:
            case 8:
                var list = Marshal.PtrToStructure<MpvNodeList>(node.Pointer);
                if (list.Count < 0 || list.Count > budget) throw new InvalidDataException("mpv list exceeds its limit.");
                JsonNode container = node.Format == 7 ? new JsonArray() : new JsonObject();
                for (var index = 0; index < list.Count; index++)
                {
                    var item = ReadNode(Marshal.PtrToStructure<MpvNode>(list.Values + index * 16), depth + 1, ref budget, ref bytes);
                    if (container is JsonArray array) array.Add(item);
                    else ((JsonObject)container)[ReadString(Marshal.ReadIntPtr(list.Keys, index * nint.Size), ref bytes)] = item;
                }
                return container;
            default: throw new InvalidDataException($"Unsupported mpv node format {node.Format}.");
        }
    }

    public void Dispose()
    {
        foreach (var pointer in allocations) Marshal.FreeHGlobal(pointer);
        foreach (var pointer in utf8Allocations) Marshal.FreeCoTaskMem(pointer);
    }
}

internal sealed class MpvNative : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayInfo
    {
        public uint Size, Bits, ColorSpace, HdrActive;
        public float Minimum, Maximum, FullFrameMaximum;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int QueryDisplay(nint window, ref DisplayInfo info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate uint ApiVersion();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate nint CreateHandle();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int InitializeHandle(nint handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void DestroyHandle(nint handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Option(nint handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Get(nint handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, int format, out MpvNode result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Set(nint handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, int format, ref MpvNode value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Command(nint handle, ref MpvNode arguments, out MpvNode result);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void FreeNode(ref MpvNode node);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate nint WaitEvent(nint handle, double timeout);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void WakeCallback(nint context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void SetWakeCallback(nint handle, WakeCallback? callback, nint context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Observe(nint handle, ulong userData, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, int format);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Unobserve(nint handle, ulong userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate nint ErrorString(int error);

    private nint library;
    private nint windowsLibrary;
    public readonly CreateHandle Create;
    public readonly InitializeHandle Initialize;
    public readonly DestroyHandle Destroy;
    public readonly Option SetOption;
    public readonly Get GetProperty;
    public readonly Set SetProperty;
    public readonly Command Execute;
    public readonly FreeNode Free;
    public readonly WaitEvent Wait;
    public readonly SetWakeCallback SetWake;
    public readonly Observe ObserveProperty;
    public readonly Unobserve UnobserveProperty;
    private readonly ErrorString errorString;
    private readonly QueryDisplay queryDisplay;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadLibraryExW(string path, nint file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool FreeLibrary(nint module);

    public MpvNative(string directory)
    {
        if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("MPVKit.Windows currently requires Windows x64.");
        var path = Path.Combine(Path.GetFullPath(directory), "libmpv-2.dll");
        if (!File.Exists(path)) throw new FileNotFoundException("Build or supply the MPVKit Windows runtime first.", path);
        library = LoadLibraryExW(path, 0, 0x100 | 0x1000);
        if (library == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load libmpv and its runtime dependencies.");
        try
        {
            windowsLibrary = LoadLibraryExW(Path.Combine(Path.GetDirectoryName(path)!, "mpvkit-windows.dll"), 0, 0x100 | 0x1000);
            if (windowsLibrary == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load the MPVKit Windows display backend.");
            queryDisplay = Marshal.GetDelegateForFunctionPointer<QueryDisplay>(NativeLibrary.GetExport(windowsLibrary, "mpvkit_query_display"));
            var version = Export<ApiVersion>("mpv_client_api_version")();
            if ((version >> 16) != 2 || (version & 0xffff) < 5)
                throw new NotSupportedException("MPVKit.Windows requires libmpv client API 2.5 or newer within major 2 (mpv 0.41+).");
            Create = Export<CreateHandle>("mpv_create");
            Initialize = Export<InitializeHandle>("mpv_initialize");
            Destroy = Export<DestroyHandle>("mpv_terminate_destroy");
            SetOption = Export<Option>("mpv_set_option_string");
            GetProperty = Export<Get>("mpv_get_property");
            SetProperty = Export<Set>("mpv_set_property");
            Execute = Export<Command>("mpv_command_node");
            Free = Export<FreeNode>("mpv_free_node_contents");
            Wait = Export<WaitEvent>("mpv_wait_event");
            SetWake = Export<SetWakeCallback>("mpv_set_wakeup_callback");
            ObserveProperty = Export<Observe>("mpv_observe_property");
            UnobserveProperty = Export<Unobserve>("mpv_unobserve_property");
            errorString = Export<ErrorString>("mpv_error_string");
        }
        catch { Dispose(); throw; }
    }

    private T Export<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, name));
    public void Check(int status, string operation)
    {
        if (status < 0) throw new MpvException(operation, status, Marshal.PtrToStringUTF8(errorString(status)) ?? "Unknown error");
    }

    public void Dispose()
    {
        var module = Interlocked.Exchange(ref library, 0);
        if (module != 0) FreeLibrary(module);
        var windowsModule = Interlocked.Exchange(ref windowsLibrary, 0);
        if (windowsModule != 0) FreeLibrary(windowsModule);
    }

    public MpvDisplayInfo GetDisplay(nint window)
    {
        var info = new DisplayInfo { Size = (uint)Marshal.SizeOf<DisplayInfo>() };
        var status = queryDisplay(window, ref info);
        return new(status >= 0, status >= 0 && info.HdrActive != 0, (int)info.Bits, (int)info.ColorSpace,
            info.Minimum, info.Maximum, info.FullFrameMaximum);
    }
}

public sealed class MpvException(string operation, int code, string detail) : Exception($"{operation}: {detail} ({code}).")
{
    public int Code { get; } = code;
}

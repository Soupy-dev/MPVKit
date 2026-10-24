using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MPVKit.Windows;

public sealed class MpvVideoHost : IDisposable
{
    private const uint Child = 0x40000000;
    private const uint Visible = 0x10000000;
    private const uint ClipChildren = 0x02000000;
    private const uint ClipSiblings = 0x04000000;
    private static readonly object ClassGate = new();
    private static readonly Dictionary<nint, MpvVideoHost> Overlays = [];
    private static readonly WindowProc Procedure = OverlayProcedure;
    private static ushort windowClass;
    private readonly uint threadId = GetCurrentThreadId();
    private readonly nint parent;
    private nint overlay;
    private Rect inlineRect;
    private bool disposed;

    public nint Handle { get; private set; }
    public MpvPlayer Player { get; }
    public bool IsCompactOverlay => overlay != 0;

    public MpvVideoHost(nint parentWindow, int width, int height, MpvPlayerOptions? options = null)
    {
        if (parentWindow == 0 || !IsWindow(parentWindow)) throw new ArgumentException("A live parent HWND is required.");
        parent = parentWindow;
        Handle = CreateWindowExW(0, "STATIC", "MPVKit video", Child | Visible | ClipChildren | ClipSiblings,
            0, 0, Math.Max(1, width), Math.Max(1, height), parent, 0, 0, 0);
        if (Handle == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { Player = new(Handle, options); }
        catch { DestroyWindow(Handle); Handle = 0; throw; }
    }

    private void CheckThread()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (GetCurrentThreadId() != threadId) throw new InvalidOperationException("Operate the video host on its creating UI thread.");
    }

    public void Resize(int x, int y, int width, int height)
    {
        CheckThread();
        if (width < 0 || height < 0 || width > 16384 || height > 16384) throw new ArgumentOutOfRangeException(nameof(width));
        inlineRect = new() { Left = x, Top = y, Right = x + width, Bottom = y + height };
        if (overlay == 0) Position(Handle, 0, x, y, width, height, 0x14);
    }

    public void ShowCompactOverlay(int width = 480, int height = 270)
    {
        CheckThread();
        if (overlay != 0) return;
        if (width is < 160 or > 1920 || height is < 90 or > 1080) throw new ArgumentOutOfRangeException(nameof(width));
        EnsureClass();
        GetWindowRect(Handle, out inlineRect);
        MapWindowPoints(0, parent, ref inlineRect, 2);
        overlay = CreateWindowExW(0x00000008 | 0x00000080, "MPVKit.CompactOverlay", "MPVKit", 0x00CF0000 | ClipChildren,
            unchecked((int)0x80000000), unchecked((int)0x80000000), width, height, parent, 0, GetModuleHandleW(null), 0);
        if (overlay == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        lock (ClassGate) Overlays.Add(overlay, this);
        if (SetParent(Handle, overlay) == 0)
        {
            RestoreInline();
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot move the existing playback surface into compact overlay.");
        }
        GetClientRect(overlay, out var size);
        Position(Handle, 0, 0, 0, size.Right, size.Bottom, 0x14);
        ShowWindow(overlay, 5);
    }

    public void RestoreInline()
    {
        CheckThread();
        if (overlay == 0) return;
        if (!IsWindow(parent)) throw new InvalidOperationException("Restore or stop playback before destroying its parent window.");
        if (SetParent(Handle, parent) == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        var old = overlay;
        overlay = 0;
        lock (ClassGate) Overlays.Remove(old);
        Position(Handle, 0, inlineRect.Left, inlineRect.Top, inlineRect.Right - inlineRect.Left, inlineRect.Bottom - inlineRect.Top, 0x14);
        DestroyWindow(old);
    }

    private static nint OverlayProcedure(nint hwnd, uint message, nuint wparam, nint lparam)
    {
        MpvVideoHost? host;
        lock (ClassGate) Overlays.TryGetValue(hwnd, out host);
        if (host is not null)
        {
            if (message == 0x0010)
            {
                host.RestoreInline();
                return 0;
            }
            if (message == 0x0005)
            {
                GetClientRect(hwnd, out var size);
                SetWindowPos(host.Handle, 0, 0, 0, size.Right, size.Bottom, 0x14);
                return 0;
            }
            if (message == 0x02E0)
            {
                var suggested = Marshal.PtrToStructure<Rect>(lparam);
                SetWindowPos(hwnd, 0, suggested.Left, suggested.Top, suggested.Right - suggested.Left, suggested.Bottom - suggested.Top, 0x14);
                return 0;
            }
        }
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }

    private static void EnsureClass()
    {
        lock (ClassGate)
        {
            if (windowClass != 0) return;
            var registration = new WindowClass { Size = (uint)Marshal.SizeOf<WindowClass>(),
                Procedure = Marshal.GetFunctionPointerForDelegate(Procedure), Instance = GetModuleHandleW(null),
                Name = "MPVKit.CompactOverlay", Cursor = LoadCursorW(0, 32512) };
            windowClass = RegisterClassExW(ref registration);
            if (windowClass == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static void Position(nint hwnd, nint after, int x, int y, int width, int height, uint flags)
    {
        if (!SetWindowPos(hwnd, after, x, y, width, height, flags)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public void Dispose()
    {
        if (disposed) return;
        CheckThread();
        if (Player.Snapshot.State != MpvPlaybackState.Disposed)
            throw new InvalidOperationException("Await Player.DisposeAsync() before destroying its HWND.");
        if (overlay != 0) RestoreInline();
        DestroyWindow(Handle);
        Handle = 0;
        disposed = true;
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Size, Style;
        public nint Procedure;
        public int ClassExtra, WindowExtra;
        public nint Instance, Icon, Cursor, Background;
        public string? Menu;
        public string Name;
        public nint SmallIcon;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate nint WindowProc(nint hwnd, uint message, nuint wparam, nint lparam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandleW(string? name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassExW(ref WindowClass value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateWindowExW(uint extended, string className, string title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint DefWindowProcW(nint hwnd, uint message, nuint wparam, nint lparam);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetParent(nint child, nint parent);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern int MapWindowPoints(nint from, nint to, ref Rect points, uint count);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(nint hwnd, int command);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint LoadCursorW(nint instance, nint name);
}

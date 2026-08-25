using System.Runtime.InteropServices;

namespace Pauselet.App;

/// <summary>
/// The small set of Win32 calls the overlay windows need: pinning to physical
/// monitor bounds above the taskbar, re-asserting topmost, and keeping the
/// subtle card from ever taking focus.
/// </summary>
internal static class NativeMethods
{
    public static readonly IntPtr HWND_TOPMOST = new(-1);

    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_TOPMOST = 0x00000008;

    public const int WM_DISPLAYCHANGE = 0x007E;

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(
        IntPtr hWnd, int attribute, ref int value, int size);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong32(IntPtr hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int index, int value);

    public static IntPtr GetWindowLongPtr(IntPtr hWnd, int index) =>
        IntPtr.Size == 8
            ? GetWindowLongPtr64(hWnd, index)
            : new IntPtr(GetWindowLong32(hWnd, index));

    public static IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value) =>
        IntPtr.Size == 8
            ? SetWindowLongPtr64(hWnd, index, value)
            : new IntPtr(SetWindowLong32(hWnd, index, value.ToInt32()));

    /// <summary>Adds extended window styles to an existing window.</summary>
    public static void AddExStyle(IntPtr hWnd, int style)
    {
        var current = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(current | (uint)style));
    }
}

# capture-game.ps1 - grab a game window even when it is occluded (rev 2, 2026-11-19)
#
# Why rev 2: the old version used CopyFromScreen only, which cannot see an occluded window -
# DWM drops the hidden part, so a covered game window captures as mostly black
# (that is exactly what happened to the other agent on 2026-11-19).
#
# Strategy, in this order:
#   1. PrintWindow with PW_RENDERFULLCONTENT (flag 2) - works for many DirectX windows even
#      when they are behind other windows and never got focus.
#   2. If the result is still almost entirely black, bring the window to the front
#      (unless -NoFront) and fall back to CopyFromScreen.
#   3. Report which route produced the image, plus a black-ratio number, so the caller
#      can tell a real screenshot from a garbage one.
#
# Usage:
#   powershell -File capture-game.ps1                     # foreground window
#   powershell -File capture-game.ps1 -Title Stardew      # window whose title contains this
#   powershell -File capture-game.ps1 -Out D:\QQBridge\shot.png
#   powershell -File capture-game.ps1 -NoFront            # never steal focus

param(
    [string]$Title = '',
    [string]$Out = 'D:\QQBridge\stardew-shot.png',
    [switch]$NoFront
)

Add-Type -AssemblyName System.Drawing

# DPI 感知：必须先声明，否则 GetWindowRect/CopyFromScreen 拿到的是被系统缩放过的逻辑坐标。
# 2026-11-19 实测：屏幕 1.75 缩放时，脚本拿到 1463x823，游戏其实画 2560x1440，结果只抓了左上角一块。
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DpiAware {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static void Enable() {
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch { } // 2 = per-monitor
        try { SetProcessDPIAware(); } catch { }
    }
}
'@
[DpiAware]::Enable()
Start-Sleep -Milliseconds 200

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class W32G {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    public delegate bool EnumProc(IntPtr h, IntPtr p);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // 2 = PW_RENDERFULLCONTENT: required for DirectX/composited windows.
    public const uint PRINT_FULL = 2;

    public static IntPtr FindByTitle(string needle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len == 0) return true;
            StringBuilder sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string TitleOf(IntPtr h) {
        int len = GetWindowTextLength(h);
        StringBuilder sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
'@

function 黑占比($bmp) {
    # 粗略采样：每 8 个像素取一个，统计接近纯黑的占比
    $black = 0; $total = 0
    $stepX = [Math]::Max(1, [int]($bmp.Width / 64))
    $stepY = [Math]::Max(1, [int]($bmp.Height / 64))
    for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
            $c = $bmp.GetPixel($x, $y)
            $total++
            if ($c.R -lt 8 -and $c.G -lt 8 -and $c.B -lt 8) { $black++ }
        }
    }
    if ($total -eq 0) { return 1.0 }
    return [Math]::Round($black / $total, 3)
}

$h = [IntPtr]::Zero
if ($Title) {
    $h = [W32G]::FindByTitle($Title)
    if ($h -eq [IntPtr]::Zero) { Write-Error "没找到标题含「$Title」的窗口"; exit 2 }
} else {
    $h = [W32G]::GetForegroundWindow()
}
if ($h -eq [IntPtr]::Zero) { Write-Error '拿不到窗口句柄'; exit 3 }

if ([W32G]::IsIconic($h)) { [W32G]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 500 }

$title = [W32G]::TitleOf($h)
$r = New-Object W32G+RECT
[W32G]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if ($w -le 0 -or $ht -le 0) { Write-Error '窗口尺寸无效（可能已最小化）'; exit 4 }

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$route = 'PrintWindow'

# ── 1) PrintWindow + PW_RENDERFULLCONTENT（不用抢焦点）────────────────
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = $false
try { $ok = [W32G]::PrintWindow($h, $hdc, [W32G]::PRINT_FULL) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
$ratio = if ($ok) { 黑占比 $bmp } else { 1.0 }

# ── 2) 还是黑的：前置窗口，再从屏幕抓 ────────────────────────────────
if ($ratio -gt 0.9 -and -not $NoFront) {
    $route = 'CopyFromScreen(前置后)'
    [W32G]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 700
    $bmp2 = New-Object System.Drawing.Bitmap $w, $ht
    $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
    try { $g2.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp2.Size) } catch {
        Write-Error ('截屏失败：' + $_.Exception.Message); exit 5
    } finally { $g2.Dispose() }
    $ratio2 = 黑占比 $bmp2
    if ($ratio2 -le $ratio) { $bmp.Dispose(); $bmp = $bmp2; $ratio = $ratio2 }
    else { $bmp2.Dispose(); $route = 'PrintWindow(前置无效，保留原图)' }
}

$dir = Split-Path $Out -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$verdict = if ($ratio -gt 0.9) { '⚠ 基本全黑，这次没抓到画面' } else { '看起来是正常画面' }
Write-Output ("window: {0}  {1}x{2}  方式: {3}  黑占比: {4}  -> {5}" -f $title, $w, $ht, $route, $ratio, $Out)
Write-Output ("判断: {0}" -f $verdict)

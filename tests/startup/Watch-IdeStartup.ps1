# Starts a Delphi IDE and watches its start, the way a person opens Delphi with no project.
# Runs ON the test desktop (started through cscoder-common\testes\Start-OnTestDesktop.ps1):
# every new window of that bds.exe is written down with its texts and captured from the window
# itself (PrintWindow); the main window is captured along the way. Ends only that bds.exe.
param(
    [Parameter(Mandatory = $true)][string]$Bds,
    [Parameter(Mandatory = $true)][string]$OutputFolder,
    [Parameter(Mandatory = $true)][string]$IdeProfile,
    [string]$ExtraArguments = '',
    [int]$Seconds = 120,
    # Show the splash screen, as the Start menu shortcut does.
    [switch]$Splash
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$log = Join-Path $OutputFolder 'startup.log'
function Note([string]$text) { Add-Content -LiteralPath $log -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $text) -Encoding UTF8 }
try {
    Add-Type -AssemblyName System.Drawing
    Add-Type -Namespace CSCoder -Name Watch -ReferencedAssemblies System.Drawing -MemberDefinition @'
public delegate bool EnumProc(IntPtr window, IntPtr param);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr param);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr param);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr window, out int processId);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
[DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr window);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int max);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr window, int msg, IntPtr w, System.Text.StringBuilder l, int flags, int timeout, out IntPtr result);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
public static System.Collections.Generic.List<IntPtr> Windows(int processId) {
    var list = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr w, IntPtr p) { int id; GetWindowThreadProcessId(w, out id); if (id == processId && IsWindowVisible(w)) list.Add(w); return true; }, IntPtr.Zero);
    return list;
}
public static string Text(IntPtr w) {
    var text = new System.Text.StringBuilder(2048); IntPtr r;
    SendMessageTimeout(w, 0x000D, (IntPtr)2048, text, 2, 1000, out r);
    return text.ToString();
}
public static string Class(IntPtr w) { var c = new System.Text.StringBuilder(256); GetClassName(w, c, 256); return c.ToString(); }
public static string Texts(IntPtr parent) {
    var all = new System.Text.StringBuilder();
    EnumChildWindows(parent, delegate(IntPtr w, IntPtr p) { if (IsWindowVisible(w)) { string t = Text(w); if (t.Length > 0) all.Append(" [" + Class(w) + ": " + t.Replace("\r", " ").Replace("\n", " ") + "]"); } return true; }, IntPtr.Zero);
    return all.ToString();
}
'@
    function Shot($w, [string]$name) {
        $rect = New-Object CSCoder.Watch+RECT
        [void][CSCoder.Watch]::GetWindowRect($w, [ref]$rect)
        $width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
        if ($width -lt 20 -or $height -lt 20) { return }
        $bitmap = New-Object System.Drawing.Bitmap $width, $height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $graphics.GetHdc()
        [void][CSCoder.Watch]::PrintWindow($w, $dc, [uint32]2)
        $graphics.ReleaseHdc($dc); $graphics.Dispose()
        $bitmap.Save((Join-Path $OutputFolder "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
    }
    $arguments = ("-r $IdeProfile " + $(if ($Splash) { "" } else { "-ns " }) + $ExtraArguments).Trim()
    $ide = Start-Process -FilePath $Bds -ArgumentList $arguments -PassThru
    Note "bds iniciado, pid $($ide.Id), argumentos: $arguments"
    $seen = @{}; $count = 0; $start = Get-Date; $mainShots = 0
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 1500
        if ($ide.HasExited) { Note "BDS ENCERROU SOZINHO, codigo $($ide.ExitCode)"; break }
        foreach ($w in [CSCoder.Watch]::Windows($ide.Id)) {
            $key = [string]$w
            $class = [CSCoder.Watch]::Class($w)
            $title = [CSCoder.Watch]::Text($w)
            if ($class -eq 'TAppBuilder') {
                $elapsed = ((Get-Date) - $start).TotalSeconds
                if (($mainShots -eq 0 -and $elapsed -gt 40) -or ($mainShots -eq 1 -and $elapsed -gt $Seconds - 10)) {
                    $mainShots++; Shot $w "principal-$mainShots"
                    Note ("janela principal capturada ({0}){1}" -f $title, $(if ([CSCoder.Watch]::IsHungAppWindow($w)) { ' NAO RESPONDE' } else { '' }))
                }
            }
            $signature = "$class|$title"
            if ($seen.ContainsKey($key) -and $seen[$key] -eq $signature) { continue }
            $seen[$key] = $signature
            if ($class -in 'TAppBuilder', 'TPUtilWindow', 'TApplication') { Note "janela $class '$title'"; continue }
            $count++
            Note ("JANELA {0}: classe={1} titulo='{2}' textos:{3}" -f $count, $class, $title, [CSCoder.Watch]::Texts($w))
            Shot $w ("janela-{0}" -f $count)
        }
    }
    if (-not $ide.HasExited) { Stop-Process -Id $ide.Id -Force; Note 'bds encerrado pelo teste' }
    Note 'FIM'
} catch {
    Note "ERRO: $($_.Exception.Message)"
    if ($ide -and -not $ide.HasExited) { Stop-Process -Id $ide.Id -Force }
    exit 1
}

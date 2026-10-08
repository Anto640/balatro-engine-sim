# tools/game_click.ps1 -- drive the live game when self-play is stuck: optional click at (x, y) in 1280x720 screenshot
# coordinates (the screen is 2560x1440, so it clicks at 2x), optional SendKeys text (F-keys do NOT reach LOVE), then
# saves a screenshot to $env:CLAUDE_JOB_DIR\tmp\<name>.png (1280x720) and <name>_full.png. Refuses without a Balatro window.
# usage: powershell -File tools/game_click.ps1 [-x 640 -y 219] [-name shot] [-wait 3] [-key "{ENTER}"]
param([int]$x = -1, [int]$y = -1, [string]$name = "shot", [int]$wait = 3, [string]$key = "")
$sig = @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@
Add-Type -MemberDefinition $sig -Name U -Namespace W -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$p = Get-Process Balatro -ErrorAction SilentlyContinue
if (-not $p -or $p.MainWindowHandle -eq 0) { "NO BALATRO WINDOW - not clicking"; exit 1 }
[W.U]::SetForegroundWindow($p.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 300
if ($x -ge 0) {
  [W.U]::SetCursorPos($x * 2, $y * 2) | Out-Null; Start-Sleep -Milliseconds 200
  [W.U]::mouse_event(2,0,0,0,0); Start-Sleep -Milliseconds 80; [W.U]::mouse_event(4,0,0,0,0)
}
if ($key -ne "") { [System.Windows.Forms.SendKeys]::SendWait($key) }
Start-Sleep -Seconds $wait
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
[System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
(New-Object System.Drawing.Bitmap $bmp, 1280, 720).Save((Join-Path $env:CLAUDE_JOB_DIR ("tmp\" + $name + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Save((Join-Path $env:CLAUDE_JOB_DIR ("tmp\" + $name + "_full.png")), [System.Drawing.Imaging.ImageFormat]::Png)

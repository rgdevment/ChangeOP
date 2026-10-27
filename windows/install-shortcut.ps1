param([string]$Hotkey = "CTRL+ALT+M")

$script = Join-Path $PSScriptRoot "switch-to-mac.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Cambiar a Mac.lnk"

$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$shortcut.Hotkey = $Hotkey
$shortcut.WindowStyle = 7
$shortcut.IconLocation = "imageres.dll,109"
$shortcut.Save()

Write-Output "Shortcut created: $shortcutPath ($Hotkey)"

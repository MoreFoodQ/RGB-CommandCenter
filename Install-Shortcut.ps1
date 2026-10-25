# Creates a desktop shortcut "RGB 光控中心" that opens the window without a console.
[CmdletBinding()]
param(
    [string]$Name = 'RGB 光控中心'
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $root 'RGB-CommandCenter.vbs'
$desktop = [Environment]::GetFolderPath('Desktop')
$path = Join-Path $desktop ($Name + '.lnk')

$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($path)
$s.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$s.Arguments = '"' + $launcher + '"'
$s.WorkingDirectory = $root
$openRgb = Join-Path $env:ProgramFiles 'OpenRGB\OpenRGB.exe'
if (Test-Path -LiteralPath $openRgb) { $s.IconLocation = $openRgb + ',0' }
$s.Save()

Write-Host "已建立捷徑：$path"

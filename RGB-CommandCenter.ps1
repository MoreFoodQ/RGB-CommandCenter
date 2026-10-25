[CmdletBinding()]
param(
    # GUI = open the window. Other values run once without UI (handy for hotkeys or scheduled tasks):
    #   On / Off / Toggle = power all devices, Apply = re-send saved settings,
    #   Crazy / Daily = load that scene, Scan = detect devices again.
    [ValidateSet('GUI', 'On', 'Off', 'Toggle', 'Apply', 'Crazy', 'Daily', 'Scan')]
    [string]$Action = 'GUI'
)

$ErrorActionPreference = 'Stop'
$ToolRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath   = Join-Path $ToolRoot 'RGB-switch-state.json'
$DevicesPath = Join-Path $ToolRoot 'RGB-devices.json'
$LogPath     = Join-Path $ToolRoot 'RGB-CommandCenter.log'
$StepTimeoutSeconds = 45

# ---------------------------------------------------------------- text tables

# OpenRGB device_type values.
$TypeLabels = @{
    0 = '主機板'; 1 = '記憶體'; 2 = '顯示卡'; 3 = '散熱器'; 4 = '燈條'; 5 = '鍵盤'; 6 = '滑鼠'
    7 = '滑鼠墊'; 8 = '耳機'; 9 = '耳機架'; 10 = '手把'; 11 = '燈具'; 12 = '喇叭'; 13 = '虛擬裝置'
    14 = '儲存裝置'; 15 = '機殼'; 16 = '麥克風'; 17 = '配件'; 18 = '小鍵盤'; 19 = '筆電'; 20 = '螢幕'
}

# Chinese names for common OpenRGB modes (lookup ignores case). Unknown modes keep their English name.
$ModeLabels = @{
    'static' = '靜態'; 'direct' = '固定顏色'; 'breathing' = '呼吸'; 'flashing' = '閃爍'; 'double flashing' = '雙閃'
    'lightning' = '閃電'; 'meteor' = '流星'; 'double meteor' = '雙流星'; 'color pulse' = '脈衝'; 'color wave' = '色波'
    'marquee' = '跑馬燈'; 'visor' = '掃描'; 'stack' = '堆疊'; 'blink' = '眨眼'; 'rainbow wave' = '彩虹波浪'
    'rainbow flashing' = '彩虹閃爍'; 'color shift' = '色彩漸變'; 'color ring' = '彩環'; 'color ring double flashing' = '彩環雙閃'
    'planetary' = '行星'; 'energy' = '能量'; 'clock' = '時鐘'; 'fire' = '火焰'; 'spectrum cycle' = '彩虹循環'
    'rainbow' = '彩虹'; 'color cycle' = '色彩循環'; 'cycle' = '循環'; 'wave' = '波浪'; 'spiral' = '螺旋'
    'reactive' = '按鍵觸發'; 'ripple' = '漣漪'; 'strobe' = '頻閃'; 'random' = '隨機'; 'comet' = '彗星'
    'chase' = '追逐'; 'pulse' = '脈動'; 'flash' = '閃光'; 'gradient' = '漸層'; 'music' = '音樂律動'
    'starry night' = '星空'; 'rain' = '雨滴'; 'spectrum' = '光譜'; 'neon' = '霓虹'; 'twinkle' = '閃爍星光'
}
$ZoneLabels = @{ 'primary zone' = '主燈'; 'logo zone' = 'Logo'; 'entire zone' = '整區'; 'keyboard' = '鍵盤'; 'mousemat' = '滑鼠墊' }
$ModeDescs = @{
    'static' = '固定顏色，不會動。'; 'direct' = '單一顏色，可調亮度。'; 'breathing' = '顏色緩慢亮起再暗下。'
    'flashing' = '規律閃爍。'; 'double flashing' = '每次連閃兩下。'; 'lightning' = '不規則的閃電效果。'
    'meteor' = '光點沿燈條劃過。'; 'color pulse' = '顏色脈動。'; 'color wave' = '顏色像波浪流動。'
    'marquee' = '燈光沿燈條追逐。'; 'visor' = '光帶來回掃動。'; 'stack' = '光點一格一格堆起來。'
    'blink' = '短暫閃一下再熄滅。'; 'spectrum cycle' = '所有顏色輪流變換。'; 'rainbow wave' = '彩虹色流動。'
    'rainbow flashing' = '彩虹色閃爍。'; 'color shift' = '多種顏色依序漸變。'; 'fire' = '火焰跳動效果。'
}

$Presets = @(
    @{ Name = '純白'; Hex = 'FFFFFF' }
    @{ Name = '暖白'; Hex = 'FFB46B' }
    @{ Name = '冰藍'; Hex = '3FD0FF' }
    @{ Name = '深藍'; Hex = '2E5BFF' }
    @{ Name = '紫';   Hex = '9B4DFF' }
    @{ Name = '粉';   Hex = 'FF4FA3' }
    @{ Name = '紅';   Hex = 'FF2A2A' }
    @{ Name = '綠';   Hex = '34E07A' }
)

$SceneInfo = [ordered]@{
    Crazy  = @{ Label = '超誇張'; Sub = '彩虹爆閃 · 全速全亮'; Glyph = [string][char]0xE945; Colors = @('FF2A2A', 'FFC24B', '34E07A', '3FD0FF', '9B4DFF', 'FF4FA3') }
    Daily  = @{ Label = '日常';   Sub = '冰藍靜態 · 70% 亮度'; Glyph = [string][char]0xE706; Colors = @('3FD0FF', '2E5BFF') }
    AllOff = @{ Label = '全關閉'; Sub = '所有燈都關掉';       Glyph = [string][char]0xE708; Colors = @('2A3646', '1A2230') }
}

# ---------------------------------------------------------------- log

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 512KB) {
            $tail = Get-Content -LiteralPath $LogPath -Tail 1500 -Encoding UTF8
            Set-Content -LiteralPath $LogPath -Value $tail -Encoding UTF8
        }
        Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    }
    catch { }
}

function Test-Hex { param($Value) ([string]$Value) -match '^[0-9A-Fa-f]{6}$' }

# ---------------------------------------------------------------- OpenRGB profile reader
# A profile (.orp) holds every detected device with its modes and zones, in the same layout as
# OpenRGB's network protocol. Saving one is how we ask OpenRGB "what is in this PC?".

function Read-OrpProfile {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 20 -or [Text.Encoding]::ASCII.GetString($b, 0, 15) -ne 'OPENRGB_PROFILE') { throw '這不是 OpenRGB 設定檔。' }
    $r = @{ i = 20 }
    $pv = [BitConverter]::ToUInt32($b, 16)
    $u16 = { $v = [BitConverter]::ToUInt16($b, $r.i); $r.i += 2; $v }
    $u32 = { $v = [BitConverter]::ToUInt32($b, $r.i); $r.i += 4; $v }
    $i32 = { $v = [BitConverter]::ToInt32($b, $r.i); $r.i += 4; $v }
    $str = { $n = & $u16; $s = [Text.Encoding]::UTF8.GetString($b, $r.i, [Math]::Max(0, $n - 1)); $r.i += $n; $s }

    $devices = @()
    $index = 0
    while ($r.i + 4 -le $b.Length) {
        $start = $r.i
        $size = & $u32
        if ($size -lt 8 -or $start + $size -gt $b.Length) { break }
        try {
            $type = & $i32
            $name = & $str
            $vendor = if ($pv -ge 1) { & $str } else { '' }
            $desc = & $str; $null = & $str; $serial = & $str; $loc = & $str
            $modeCount = & $u16
            $null = & $i32
            $modes = @()
            for ($m = 0; $m -lt $modeCount; $m++) {
                $mn = & $str; $null = & $i32; $flags = & $u32; $smin = & $u32; $smax = & $u32
                $bmin = 0; $bmax = 0
                if ($pv -ge 3) { $bmin = & $u32; $bmax = & $u32 }
                $null = & $u32; $null = & $u32; $null = & $u32
                if ($pv -ge 3) { $null = & $u32 }
                $null = & $u32; $cm = & $u32
                $nc = & $u16; $r.i += 4 * $nc
                $modes += [pscustomobject]@{ Name = $mn; Flags = $flags; ColorMode = $cm; SpeedMin = $smin; SpeedMax = $smax; BrightMin = $bmin; BrightMax = $bmax }
            }
            $zoneCount = & $u16
            $zones = @()
            for ($z = 0; $z -lt $zoneCount; $z++) {
                $zn = & $str; $null = & $i32; $null = & $u32; $null = & $u32; $leds = & $u32
                $ml = & $u16; $r.i += $ml
                if ($pv -ge 4) { $ns = & $u16; for ($s = 0; $s -lt $ns; $s++) { $null = & $str; $null = & $i32; $null = & $u32; $null = & $u32 } }
                if ($pv -ge 5) { $null = & $u32 }
                $zones += [pscustomobject]@{ Index = $z; Name = $zn; Leds = $leds }
            }
            $devices += [pscustomobject]@{
                Index = $index; Type = $type; Name = $name; Vendor = $vendor; Description = $desc
                Serial = $serial; Location = $loc; Modes = $modes; Zones = $zones
            }
        }
        catch { Write-Log ("略過無法解析的裝置 #$index：" + $_.Exception.Message) }
        $r.i = $start + $size
        $index++
    }
    return , $devices
}

# ---------------------------------------------------------------- device catalogue (built from detection)

function ConvertTo-ModeDef {
    param($Raw, [int]$Order)
    $f = [uint32]$Raw.Flags
    $lower = ([string]$Raw.Name).ToLower()
    $color = ($f -band 0x60) -ne 0                     # per-LED or mode-specific colour
    $speed = (($f -band 0x1) -ne 0) -and ($Raw.SpeedMin -ne $Raw.SpeedMax)
    $bright = (($f -band 0x10) -ne 0) -and ($Raw.BrightMin -ne $Raw.BrightMax)
    $label = $ModeLabels[$lower]; if (-not $label) { $label = [string]$Raw.Name }
    $desc = $ModeDescs[$lower]
    if (-not $desc) {
        $bits = @(if ($color) { '可選顏色' } else { '顏色自動' })
        if ($speed) { $bits += '可調速度' }
        if ($bright) { $bits += '可調亮度' }
        $desc = ($bits -join '，') + '。'
    }
    elseif (-not $color) { $desc = $desc.TrimEnd('。') + '，顏色自動。' }
    $sort = if ($lower -eq 'static') { 0 } elseif ($lower -eq 'direct') { 1 } elseif ($lower -eq 'breathing') { 2 } elseif ($color) { 3 } else { 4 }
    [pscustomobject]@{
        Name = [string]$Raw.Name; Label = $label; Desc = $desc
        Color = $color; PerLed = ($f -band 0x20) -ne 0; Random = $color -and (($f -band 0x80) -ne 0)
        Speed = $speed; Bright = $bright; SpeedRange = [Math]::Abs([double]$Raw.SpeedMax - [double]$Raw.SpeedMin)
        Sort = $sort; Order = $Order
    }
}

function Build-Catalog {
    param($Devices)
    $Devices = @($Devices)
    $catalog = [ordered]@{}
    $typeCount = @{}
    foreach ($d in $Devices) { $typeCount[[int]$d.Type] = 1 + [int]$typeCount[[int]$d.Type] }
    $typeSeen = @{}

    foreach ($d in $Devices) {
        $raw = @($d.Modes)
        $usable = @($raw | Where-Object { $_.Name -ne 'Off' })
        # Direct is a software-only mode; hide it when the device has a real Static mode.
        if ($usable | Where-Object { $_.Name -eq 'Static' }) { $usable = @($usable | Where-Object { $_.Name -ne 'Direct' }) }
        if ($usable.Count -eq 0) { continue }
        $i = 0
        $modes = @($usable | ForEach-Object { ConvertTo-ModeDef $_ ($i++) } | Sort-Object Sort, Order)

        $zones = @($d.Zones | Where-Object { [int]$_.Leds -gt 0 } | ForEach-Object {
            $zl = $ZoneLabels[([string]$_.Name).ToLower()]
            [pscustomobject]@{ Index = [int]$_.Index; Name = $(if ($zl) { $zl } else { [string]$_.Name }) }
        })

        # --device does a substring search, so fall back to the index when the name is ambiguous.
        $name = [string]$d.Name
        $ambiguous = @($Devices | Where-Object { $_ -ne $d -and ([string]$_.Name).IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
        $target = if ($ambiguous) { [string]$d.Index } else { $name }

        $t = [int]$d.Type
        $label = $TypeLabels[$t]; if (-not $label) { $label = '裝置' }
        if ($typeCount[$t] -gt 1) { $typeSeen[$t] = 1 + [int]$typeSeen[$t]; $label = '{0} {1}' -f $label, $typeSeen[$t] }

        $speedMode = $modes | Where-Object { $_.Speed } | Select-Object -First 1
        $speedTick = if ($speedMode -and $speedMode.SpeedRange -ge 1 -and $speedMode.SpeedRange -le 4) { [int](100 / $speedMode.SpeedRange) } else { 10 }

        $note = ''
        if (-not ($modes | Where-Object { $_.Speed -or -not $_.Color })) {
            $note = '這個裝置的燈光硬體只支援固定顏色' + $(if ($modes | Where-Object { $_.Bright }) { '和亮度' } else { '' }) + '，沒有呼吸或彩虹等動態效果。'
        }
        elseif ($zones.Count -gt 1 -and ($modes | Where-Object { $_.PerLed })) {
            $note = '所有燈區共用同一種模式，但每個燈區可以設不同顏色。'
        }

        $offMode = $null
        if (-not ($raw | Where-Object { $_.Name -eq 'Off' })) {
            $offMode = $modes | Where-Object { $_.Color -and $_.Name -in 'Static', 'Direct' } | Select-Object -First 1
            if (-not $offMode) { $offMode = $modes | Where-Object { $_.Color -and -not $_.Speed } | Select-Object -First 1 }
        }

        $sub = $name
        if ($zones.Count -gt 1) { $sub += ' · {0} 個燈區' -f $zones.Count }
        $key = ('{0}|{1}' -f $name, $d.Location) -replace '\s+', ' '
        $catalog[$key] = [pscustomobject]@{
            Key = $key; Label = $label; Name = $name; Target = $target; Type = $t; Sub = $sub
            Zones = $zones; Modes = $modes; SpeedTick = $speedTick; Note = $note
            HasOff = [bool]($raw | Where-Object { $_.Name -eq 'Off' }); OffMode = $offMode
        }
    }
    return $catalog
}

function Get-ZoneCount { param([string]$Key) [Math]::Max(1, $script:Catalog[$Key].Zones.Count) }

function Get-ModeDef {
    param([string]$Key, [string]$Mode)
    $m = $script:Catalog[$Key].Modes | Where-Object { $_.Name -eq $Mode } | Select-Object -First 1
    if (-not $m) { $m = $script:Catalog[$Key].Modes[0] }
    return $m
}

# Static-looking mode used for "same colour" and the Daily scene.
function Get-PlainMode {
    param([string]$Key)
    $modes = $script:Catalog[$Key].Modes
    $m = $modes | Where-Object { $_.Name -in 'Static', 'Direct' } | Select-Object -First 1
    if (-not $m) { $m = $modes | Where-Object { $_.Color -and -not $_.Speed } | Select-Object -First 1 }
    if (-not $m) { $m = $modes | Where-Object { $_.Color } | Select-Object -First 1 }
    if (-not $m) { $m = $modes[0] }
    return $m
}

# ---------------------------------------------------------------- state

function New-DeviceState {
    param([string]$Key)
    @{ On = $true; Mode = (Get-PlainMode $Key).Name; Colors = @(1..(Get-ZoneCount $Key) | ForEach-Object { 'FFFFFF' }); Speed = 50; Brightness = 100; Random = $false }
}

function ConvertTo-DeviceState {
    param([string]$Key, $Raw)
    $d = New-DeviceState $Key
    if (-not $Raw) { return $d }
    if ($null -ne $Raw.On) { $d.On = [bool]$Raw.On }
    if ($script:Catalog[$Key].Modes.Name -contains [string]$Raw.Mode) { $d.Mode = [string]$Raw.Mode }
    $cols = @($Raw.Colors | Where-Object { Test-Hex $_ } | ForEach-Object { ([string]$_).ToUpper() })
    $n = Get-ZoneCount $Key
    if ($cols.Count -gt 0) { $d.Colors = @(0..($n - 1) | ForEach-Object { $cols[[Math]::Min($_, $cols.Count - 1)] }) }
    if ($null -ne $Raw.Speed) { $d.Speed = [Math]::Max(0, [Math]::Min(100, [int]$Raw.Speed)) }
    if ($null -ne $Raw.Brightness) { $d.Brightness = [Math]::Max(5, [Math]::Min(100, [int]$Raw.Brightness)) }
    $d.Random = [bool]$Raw.Random
    return $d
}

function Get-SavedState {
    $s = @{ Tab = 'All'; OpenRgbPath = ''; Raw = @{} }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $s }
    try {
        $saved = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Tab) { $s.Tab = [string]$saved.Tab }
        if ($saved.OpenRgbPath) { $s.OpenRgbPath = [string]$saved.OpenRgbPath }
        if ($saved.Devices) { foreach ($p in $saved.Devices.PSObject.Properties) { $s.Raw[$p.Name] = $p.Value } }
    }
    catch { Write-Log ('讀取狀態檔失敗：' + $_.Exception.Message) }
    return $s
}

# Match saved settings to the detected devices. Older files used the keys Board / Gpu / Mouse.
function Sync-DeviceStates {
    $legacy = @{ 0 = 'Board'; 2 = 'Gpu'; 6 = 'Mouse' }
    $devices = @{}
    foreach ($k in $script:Catalog.Keys) {
        $raw = $script:State.Raw[$k]
        if (-not $raw) {
            $old = $legacy[$script:Catalog[$k].Type]
            if ($old -and $script:State.Raw[$old]) { $raw = $script:State.Raw[$old]; $script:State.Raw.Remove($old) }
        }
        $devices[$k] = ConvertTo-DeviceState $k $raw
    }
    $script:State.Devices = $devices
    if ($script:State.Tab -ne 'All' -and -not $script:Catalog.Contains($script:State.Tab)) { $script:State.Tab = 'All' }
}

function Save-State {
    try {
        $out = [ordered]@{ Version = 4; Tab = $script:State.Tab; OpenRgbPath = $script:State.OpenRgbPath; Devices = [ordered]@{}; Updated = (Get-Date -Format o) }
        # Keep settings of devices that are unplugged right now, so they come back later.
        foreach ($k in $script:State.Raw.Keys) { if ($k -match '\|') { $out.Devices[$k] = $script:State.Raw[$k] } }
        foreach ($k in $script:Catalog.Keys) {
            $d = $script:State.Devices[$k]
            $out.Devices[$k] = [ordered]@{ On = $d.On; Mode = $d.Mode; Colors = @($d.Colors); Speed = $d.Speed; Brightness = $d.Brightness; Random = $d.Random }
        }
        $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
    catch { Write-Log ('儲存狀態失敗：' + $_.Exception.Message) }
}

function Set-Catalog {
    param($Devices)
    $script:Catalog = Build-Catalog $Devices
    Sync-DeviceStates
}

function Import-DeviceCache {
    if (-not (Test-Path -LiteralPath $DevicesPath)) { return $false }
    try {
        $cache = Get-Content -LiteralPath $DevicesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Set-Catalog @($cache.Devices)
        return ($script:Catalog.Count -gt 0)
    }
    catch { Write-Log ('讀取裝置快取失敗：' + $_.Exception.Message); return $false }
}

function Save-DeviceCache {
    param($Devices)
    [ordered]@{ Scanned = (Get-Date -Format o); Devices = @($Devices) } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $DevicesPath -Encoding UTF8
}

# ---------------------------------------------------------------- scenes

function Get-SceneSetting {
    param([string]$Scene, [string]$Key)
    $modes = $script:Catalog[$Key].Modes
    switch ($Scene) {
        'AllOff' { return @{ On = $false } }
        'Daily' {
            $m = Get-PlainMode $Key
            return @{ On = $true; Mode = $m.Name; Color = $(if ($m.Color) { '3FD0FF' } else { $null }); Speed = 50; Brightness = 70; Random = $false }
        }
        'Crazy' {
            foreach ($n in 'Rainbow flashing', 'Color ring double flashing', 'Spectrum Cycle', 'Rainbow wave', 'Rainbow', 'Color cycle', 'Color shift', 'Color ring', 'Spectrum') {
                $m = $modes | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                if ($m) { return @{ On = $true; Mode = $m.Name; Speed = 100; Brightness = 100; Random = $false } }
            }
            $m = $modes | Where-Object { $_.Speed -and -not $_.Color } | Select-Object -First 1
            if ($m) { return @{ On = $true; Mode = $m.Name; Speed = 100; Brightness = 100; Random = $false } }
            $m = $modes | Where-Object { $_.Random -and $_.Speed } | Select-Object -First 1
            if ($m) { return @{ On = $true; Mode = $m.Name; Speed = 100; Brightness = 100; Random = $true } }
            $m = $modes | Where-Object { $_.Color -and $_.Speed } | Select-Object -First 1
            if (-not $m) { $m = Get-PlainMode $Key }
            return @{ On = $true; Mode = $m.Name; Color = 'FF00FF'; Speed = 100; Brightness = 100; Random = $false }
        }
    }
}

function Set-Scene {
    param([string]$Name)
    foreach ($k in $script:Catalog.Keys) {
        $s = Get-SceneSetting $Name $k
        $d = $script:State.Devices[$k]
        $d.On = $s.On
        if (-not $s.On) { continue }
        $d.Mode = $s.Mode
        if ($s.Color) { $d.Colors = @(1..(Get-ZoneCount $k) | ForEach-Object { $s.Color }) }
        $d.Speed = $s.Speed
        $d.Brightness = $s.Brightness
        $d.Random = $s.Random
    }
}

function Test-SceneActive {
    param([string]$Name)
    foreach ($k in $script:Catalog.Keys) {
        $s = Get-SceneSetting $Name $k
        $d = $script:State.Devices[$k]
        if ($d.On -ne $s.On) { return $false }
        if (-not $s.On) { continue }
        if ($d.Mode -ne $s.Mode -or [bool]$d.Random -ne [bool]$s.Random) { return $false }
        $m = Get-ModeDef $k $d.Mode
        if ($s.Color -and @($d.Colors | Where-Object { $_ -ne $s.Color }).Count -gt 0) { return $false }
        if ($m.Speed -and $d.Speed -ne $s.Speed) { return $false }
        if ($m.Bright -and $d.Brightness -ne $s.Brightness) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------- OpenRGB commands

function Find-OpenRgb {
    $candidates = @(
        $script:State.OpenRgbPath
        (Join-Path $env:ProgramFiles 'OpenRGB\OpenRGB.exe')
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'OpenRGB\OpenRGB.exe' })
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenRGB\OpenRGB.exe')
        (Get-Command 'OpenRGB.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Start-OpenRgb {
    param([string[]]$Arguments)
    if (-not $script:OpenRgbPath -or -not (Test-Path -LiteralPath $script:OpenRgbPath)) { throw '找不到 OpenRGB.exe。' }
    $line = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    Write-Log ('RUN ' + $line)
    $p = Start-Process -FilePath $script:OpenRgbPath -ArgumentList $line -WindowStyle Hidden -PassThru
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    return $p
}

# Arguments that make one device match its saved settings (or switch it off).
function Get-DeviceArguments {
    param([string]$Key)
    $cat = $script:Catalog[$Key]
    $d = $script:State.Devices[$Key]
    $a = New-Object System.Collections.Generic.List[string]
    $perZone = { param($m) $m.PerLed -and $cat.Zones.Count -gt 1 }

    if (-not $d.On) {
        if ($cat.HasOff) {
            $a.AddRange([string[]]@('--device', $cat.Target, '--mode', 'Off'))
        }
        elseif ($cat.OffMode) {
            # No Off mode: black, and brightness 0 where the mode has brightness.
            $m = $cat.OffMode
            $tail = @('--mode', $m.Name, '--color', '000000') + $(if ($m.Bright) { @('--brightness', '0') } else { @() })
            if (& $perZone $m) { foreach ($z in $cat.Zones) { $a.AddRange([string[]](@('--device', $cat.Target, '--zone', [string]$z.Index) + $tail)) } }
            else { $a.AddRange([string[]](@('--device', $cat.Target) + $tail)) }
        }
        return , $a.ToArray()
    }

    $m = Get-ModeDef $Key $d.Mode
    $extra = @()
    if ($m.Speed)  { $extra += '--speed', [string]$d.Speed }
    if ($m.Bright) { $extra += '--brightness', [string]$d.Brightness }
    $useRandom = $m.Random -and $d.Random

    if ($m.Color -and -not $useRandom -and (& $perZone $m)) {
        # Same mode on every zone, each zone with its own colour.
        for ($p = 0; $p -lt $cat.Zones.Count; $p++) {
            $a.AddRange([string[]](@('--device', $cat.Target, '--zone', [string]$cat.Zones[$p].Index, '--mode', $m.Name, '--color', $d.Colors[$p]) + $extra))
        }
    }
    else {
        $a.AddRange([string[]]@('--device', $cat.Target, '--mode', $m.Name))
        if ($m.Color) { $a.AddRange([string[]]@('--color', $(if ($useRandom) { 'random' } else { $d.Colors[0] }))) }
        if ($extra) { $a.AddRange([string[]]$extra) }
    }
    return , $a.ToArray()
}

# One OpenRGB call for every requested device, so detection runs only once (~2 s).
function Get-SyncArguments {
    param([string[]]$Keys)
    $all = New-Object System.Collections.Generic.List[string]
    $all.Add('--noautoconnect')
    foreach ($k in $script:Catalog.Keys) {
        if ($Keys -contains $k) { $all.AddRange([string[]](Get-DeviceArguments $k)) }
    }
    return , $all.ToArray()
}

function New-ScanBase { Join-Path ([IO.Path]::GetTempPath()) ('rgbcc-scan-' + [guid]::NewGuid().ToString('N')) }

function Complete-Scan {
    param([string]$Base)
    $file = $Base + '.orp'
    if (-not (Test-Path -LiteralPath $file)) { throw 'OpenRGB 沒有產生裝置清單。' }
    try { $devices = Read-OrpProfile $file }
    finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    Save-DeviceCache $devices
    Set-Catalog $devices
    Write-Log ('SCAN 偵測到 {0} 個裝置：{1}' -f $script:Catalog.Count, (($script:Catalog.Values | ForEach-Object { $_.Name }) -join '、'))
}

function Test-AnyOn { [bool]($script:Catalog.Keys | Where-Object { $script:State.Devices[$_].On }) }

function Set-AllPower {
    param([bool]$On)
    foreach ($k in $script:Catalog.Keys) { $script:State.Devices[$k].On = $On }
}

$script:Catalog = [ordered]@{}
$script:State = Get-SavedState
$script:State.Devices = @{}
$script:OpenRgbPath = Find-OpenRgb

# ---------------------------------------------------------------- command-line mode

function Wait-OpenRgb {
    param($Process)
    if (-not $Process.WaitForExit($StepTimeoutSeconds * 1000)) { $Process.Kill(); throw 'OpenRGB 沒有回應（逾時）。' }
    Write-Log ('EXIT ' + $Process.ExitCode)
    if ($Process.ExitCode -ne 0) { throw "OpenRGB 回傳錯誤代碼 $($Process.ExitCode)。" }
}

if ($Action -ne 'GUI') {
    try {
        if (-not $script:OpenRgbPath) { throw '找不到 OpenRGB，請先安裝：https://openrgb.org' }
        if ($Action -eq 'Scan' -or -not (Import-DeviceCache)) {
            Write-Host '正在偵測裝置…'
            $base = New-ScanBase
            Wait-OpenRgb (Start-OpenRgb @('--noautoconnect', '--save-profile', $base))
            Complete-Scan $base
            Write-Host ('偵測到 {0} 個裝置：{1}' -f $script:Catalog.Count, (($script:Catalog.Values | ForEach-Object { "$($_.Label)（$($_.Name)）" }) -join '、'))
        }
        if ($script:Catalog.Count -eq 0) { throw '沒有偵測到可控制的 RGB 裝置。' }
        if ($Action -ne 'Scan') {
            switch ($Action) {
                'On'     { Set-AllPower $true }
                'Off'    { Set-AllPower $false }
                'Toggle' { Set-AllPower (-not (Test-AnyOn)) }
                'Crazy'  { Set-Scene 'Crazy' }
                'Daily'  { Set-Scene 'Daily' }
            }
            Wait-OpenRgb (Start-OpenRgb (Get-SyncArguments @($script:Catalog.Keys)))
            $msg = if (Test-AnyOn) { '已套用燈效' } else { '已關燈' }
            Write-Log $msg
            Write-Host $msg
        }
        Save-State
        exit 0
    }
    catch {
        Write-Log ('ERROR ' + $_.Exception.Message)
        Write-Host ('失敗：' + $_.Exception.Message)
        exit 1
    }
}

# ---------------------------------------------------------------- window

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\RGB-CommandCenter', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.MessageBox]::Show('RGB 光控中心已經開著了，請到工作列找它。', 'RGB 光控中心') | Out-Null
    exit 0
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RGB 光控中心" Width="520" Height="820"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize"
        FontFamily="Microsoft JhengHei UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#5EE6FF"/>
    <Color x:Key="AccentColor">#5EE6FF</Color>
    <Color x:Key="AccentClear">#005EE6FF</Color>
    <SolidColorBrush x:Key="TextMain" Color="#EEF3F8"/>
    <SolidColorBrush x:Key="Muted" Color="#8393A7"/>
    <SolidColorBrush x:Key="CardBg" Color="#141B26"/>
    <SolidColorBrush x:Key="Line" Color="#222D3C"/>

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1F2937"/>
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Foreground" Value="#071014"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{DynamicResource Accent}" CornerRadius="10" Padding="18,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Scene" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="BorderBrush" Value="#263243"/>
      <Setter Property="BorderThickness" Value="1.5"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform"><Setter.Value><ScaleTransform/></Setter.Value></Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="14" Padding="12,12" ClipToBounds="True">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#C9D4E0"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.97" ScaleY="0.97"/></Setter.Value></Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="GroupName" Value="Tabs"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="9" Padding="4,9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#222E3E"/>
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#A9B6C6"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="#10161F" BorderBrush="#263243" BorderThickness="1" CornerRadius="15" Padding="13,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#4A5F78"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1A2433"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- on/off switch; Tag holds the "on" track colour -->
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid Width="44" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="#2A3646"/>
              <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#C9D4E0" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="Knob" Property="Fill" Value="#0E131B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#A9B6C6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="#10161F" BorderBrush="#263243" BorderThickness="1" CornerRadius="12" Padding="10,4">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="Dot" Width="6" Height="6" Fill="#3A4757" Margin="0,0,6,0" VerticalAlignment="Center"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Dot" Property="Fill" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource TextMain}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Power" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform"><Setter.Value><ScaleTransform/></Setter.Value></Setter>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Ellipse>
                <Ellipse.Fill>
                  <RadialGradientBrush GradientOrigin="0.35,0.28" RadiusX="0.75" RadiusY="0.75">
                    <GradientStop Color="#263142" Offset="0"/>
                    <GradientStop Color="#111720" Offset="1"/>
                  </RadialGradientBrush>
                </Ellipse.Fill>
              </Ellipse>
              <Ellipse x:Name="Hover" Fill="#FFFFFF" Opacity="0"/>
              <Ellipse Stroke="{TemplateBinding BorderBrush}" StrokeThickness="3" Margin="6"/>
              <TextBlock Text="&#xE7E8;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="36"
                         Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hover" Property="Opacity" Value="0.05"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Swatch" TargetType="Button">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#C9D4E0"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform"><Setter.Value><ScaleTransform/></Setter.Value></Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Ellipse Stroke="{TemplateBinding BorderBrush}" StrokeThickness="2"/>
              <Ellipse Fill="{TemplateBinding Background}" Margin="5"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1.1" ScaleY="1.1"/></Setter.Value></Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SliderFill" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Height="6" CornerRadius="3" Background="{DynamicResource Accent}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SliderRest" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FlatSlider" TargetType="Slider">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="24" Background="Transparent">
              <Border Height="6" CornerRadius="3" Background="#263243" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Style="{StaticResource SliderFill}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Style="{StaticResource SliderRest}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Width="18" Height="18" Fill="#EEF3F8" Stroke="#0E131B" StrokeThickness="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="3" Background="#2E3A4B"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ThinScroll" TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Focusable" Value="False"/>
    </Style>
  </Window.Resources>

  <Border Margin="12" CornerRadius="22" Background="#0E131B" BorderBrush="#222D3C" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.5" Color="#000000"/>
    </Border.Effect>
    <Grid Margin="20,14,20,14">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- title bar -->
      <Grid x:Name="TitleBar" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="RGB 光控中心" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource TextMain}"/>
          <TextBlock x:Name="Subtitle" Text="" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
          <Button x:Name="MinButton" Style="{StaticResource Ghost}" ToolTip="縮到工作列" Padding="10,8"
                  Content="&#xE921;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11"/>
          <Button x:Name="CloseButton" Style="{StaticResource Ghost}" ToolTip="關閉 (Esc)" Padding="10,8"
                  Content="&#xE8BB;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11"/>
        </StackPanel>
      </Grid>

      <!-- tabs (one per detected device) -->
      <Border x:Name="TabBar" Grid.Row="1" Background="#10161F" BorderBrush="#1C2533" BorderThickness="1" CornerRadius="12" Padding="4" Margin="0,14,0,14">
        <UniformGrid x:Name="TabGrid" Rows="1"/>
      </Border>

      <!-- setup / scanning / problem page -->
      <StackPanel x:Name="SetupPage" Grid.Row="1" Grid.RowSpan="2" VerticalAlignment="Center" Margin="16,0" Visibility="Collapsed">
        <TextBlock x:Name="SetupGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="40" HorizontalAlignment="Center" Foreground="{DynamicResource Accent}"/>
        <TextBlock x:Name="SetupTitle" FontSize="18" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,16,0,0" Foreground="{StaticResource TextMain}"/>
        <TextBlock x:Name="SetupText" FontSize="13" Foreground="{StaticResource Muted}" TextAlignment="Center" TextWrapping="Wrap" Margin="0,8,0,20" LineHeight="20"/>
        <StackPanel x:Name="SetupButtons" Orientation="Horizontal" HorizontalAlignment="Center">
          <Button x:Name="SetupPrimary" Style="{StaticResource Primary}" Margin="0,0,8,0"/>
          <Button x:Name="SetupSecondary" Style="{StaticResource Ghost}" Padding="14,10" FontSize="13"/>
        </StackPanel>
      </StackPanel>

      <!-- overview page -->
      <ScrollViewer x:Name="OverviewPage" Grid.Row="2" Style="{StaticResource ThinScroll}" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="一鍵情境" Style="{StaticResource Label}" Margin="2,0,0,8"/>
          <UniformGrid x:Name="SceneGrid" Columns="3" Margin="-4,0,-4,14"/>

          <Border Style="{StaticResource Card}" Padding="16,10">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid Width="104" Height="104">
                <Ellipse x:Name="PowerGlow" Width="104" Height="104" Opacity="0.35" IsHitTestVisible="False">
                  <Ellipse.Fill>
                    <RadialGradientBrush>
                      <GradientStop Color="{DynamicResource AccentColor}" Offset="0.5"/>
                      <GradientStop Color="{DynamicResource AccentClear}" Offset="1"/>
                    </RadialGradientBrush>
                  </Ellipse.Fill>
                </Ellipse>
                <Button x:Name="PowerButton" Style="{StaticResource Power}" Width="84" Height="84"
                        BorderBrush="{DynamicResource Accent}" Foreground="{DynamicResource Accent}" ToolTip="全部開／關（空白鍵）"/>
              </Grid>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                <TextBlock x:Name="PowerTitle" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource TextMain}"/>
                <TextBlock x:Name="PowerHint" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,4,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Style="{StaticResource Card}" Padding="6,4">
            <StackPanel x:Name="DeviceRows"/>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="全部同色（所有裝置一起改成靜態單色）" Style="{StaticResource Label}" Margin="0,0,0,10"/>
              <UniformGrid x:Name="AllSwatchGrid" Columns="9" Rows="1"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- device page (filled in for the selected device) -->
      <ScrollViewer x:Name="DevicePage" Grid.Row="2" Style="{StaticResource ThinScroll}" Visibility="Collapsed">
        <StackPanel>
          <Grid Margin="2,0,2,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="DevTitle" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource TextMain}"/>
              <TextBlock x:Name="DevSub" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="DevSwitchText" FontSize="13" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <ToggleButton x:Name="DevSwitch" Style="{StaticResource Switch}"/>
            </StackPanel>
          </Grid>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="燈效模式" Style="{StaticResource Label}" Margin="0,0,0,10"/>
              <WrapPanel x:Name="ModeWrap"/>
              <TextBlock x:Name="ModeDesc" FontSize="12" Foreground="{StaticResource Muted}" Margin="2,4,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>

          <Border x:Name="ColorCard" Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,10">
                <TextBlock Text="顏色" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                <ToggleButton x:Name="RandomToggle" Style="{StaticResource Chip}" Content="隨機顏色" HorizontalAlignment="Right"/>
              </Grid>
              <WrapPanel x:Name="ZoneWrap" Margin="0,0,0,6"/>
              <UniformGrid x:Name="DevSwatchGrid" Columns="9" Rows="1"/>
              <TextBlock x:Name="RandomNote" Text="由燈光自己隨機挑選顏色。" FontSize="12" Foreground="{StaticResource Muted}" Visibility="Collapsed"/>
            </StackPanel>
          </Border>

          <Border x:Name="SpeedCard" Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,6">
                <TextBlock Text="速度" Style="{StaticResource Label}"/>
                <TextBlock x:Name="SpeedText" Style="{StaticResource Label}" HorizontalAlignment="Right" Foreground="{StaticResource TextMain}"/>
              </Grid>
              <Slider x:Name="SpeedSlider" Style="{StaticResource FlatSlider}" TickFrequency="10"/>
              <Grid Margin="0,2,0,0">
                <TextBlock Text="慢" Style="{StaticResource Label}"/>
                <TextBlock Text="快" Style="{StaticResource Label}" HorizontalAlignment="Right"/>
              </Grid>
            </StackPanel>
          </Border>

          <Border x:Name="BrightCard" Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,6">
                <TextBlock Text="亮度" Style="{StaticResource Label}"/>
                <TextBlock x:Name="BrightText" Style="{StaticResource Label}" HorizontalAlignment="Right" Foreground="{StaticResource TextMain}"/>
              </Grid>
              <Slider x:Name="BrightSlider" Style="{StaticResource FlatSlider}" Minimum="5" TickFrequency="5"/>
            </StackPanel>
          </Border>

          <TextBlock x:Name="DevNote" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="4,2,4,8"/>
        </StackPanel>
      </ScrollViewer>

      <!-- status -->
      <Grid Grid.Row="3" Margin="2,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#34E07A" VerticalAlignment="Center" Margin="0,0,9,0"/>
        <TextBlock x:Name="StatusText" Grid.Column="1" Text="" FontSize="12" Foreground="{StaticResource Muted}"
                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <Button x:Name="ScanButton" Grid.Column="2" Style="{StaticResource Ghost}" Content="重新偵測" ToolTip="重新偵測電腦裡的 RGB 裝置"/>
        <Button x:Name="LogButton" Grid.Column="3" Style="{StaticResource Ghost}" Content="紀錄" ToolTip="打開 RGB-CommandCenter.log"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
$ui = @{}
foreach ($n in 'TitleBar', 'Subtitle', 'MinButton', 'CloseButton', 'TabBar', 'TabGrid',
               'SetupPage', 'SetupGlyph', 'SetupTitle', 'SetupText', 'SetupButtons', 'SetupPrimary', 'SetupSecondary',
               'OverviewPage', 'SceneGrid', 'PowerGlow', 'PowerButton', 'PowerTitle', 'PowerHint', 'DeviceRows', 'AllSwatchGrid',
               'DevicePage', 'DevTitle', 'DevSub', 'DevSwitchText', 'DevSwitch', 'ModeWrap', 'ModeDesc',
               'ColorCard', 'RandomToggle', 'ZoneWrap', 'DevSwatchGrid', 'RandomNote',
               'SpeedCard', 'SpeedText', 'SpeedSlider', 'BrightCard', 'BrightText', 'BrightSlider', 'DevNote',
               'StatusDot', 'StatusText', 'ScanButton', 'LogButton') {
    $ui[$n] = $window.FindName($n)
}

function Set-WindowIcon {
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:OpenRgbPath)
        $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    }
    catch { }
}

# ---------------------------------------------------------------- helpers

function ConvertTo-Brush {
    param([string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#' + $Hex))
    $b.Freeze()
    return $b
}

function New-GradientBrush {
    param([string[]]$Hexes, [double]$Opacity = 1)
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = '0,0'; $g.EndPoint = '1,1'
    for ($i = 0; $i -lt $Hexes.Count; $i++) {
        $off = if ($Hexes.Count -gt 1) { $i / ($Hexes.Count - 1) } else { 0 }
        $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#' + $Hexes[$i])), $off))
    }
    $g.Opacity = $Opacity
    $g.Freeze()
    return $g
}

$Transparent = [System.Windows.Media.Brushes]::Transparent
$RingBrush = ConvertTo-Brush 'EEF3F8'
$RainbowBrush = New-GradientBrush @('FF2A2A', 'FFC24B', '34E07A', '3FD0FF', '9B4DFF')

function Get-ColorLabel {
    param([string]$Hex)
    $match = $Presets | Where-Object { $_.Hex -eq $Hex } | Select-Object -First 1
    if ($match) { return $match.Name }
    if ($Hex -eq 'FF00FF') { return '洋紅' }
    return '#' + $Hex
}

# The colour that represents a device in the UI ($null = rainbow / random).
function Get-DeviceAccentHex {
    param([string]$Key)
    $d = $script:State.Devices[$Key]
    if (-not $d.On) { return '4A5668' }
    $m = Get-ModeDef $Key $d.Mode
    if (-not $m.Color -or ($m.Random -and $d.Random)) { return $null }
    return $d.Colors[0]
}

function Get-SpeedLabel {
    param([string]$Key, [int]$Value)
    if ($script:Catalog[$Key].SpeedTick -ge 50) { return @{ 0 = '慢'; 50 = '中'; 100 = '快' }[[int]([Math]::Round($Value / 50) * 50)] }
    return '{0}%' -f $Value
}

function Get-DeviceSummary {
    param([string]$Key)
    $d = $script:State.Devices[$Key]
    if (-not $d.On) { return '已關閉' }
    $m = Get-ModeDef $Key $d.Mode
    $parts = @($m.Label)
    if ($m.Color) {
        if ($m.Random -and $d.Random) { $parts += '隨機色' }
        elseif (@($d.Colors | Select-Object -Unique).Count -gt 1) { $parts += '多色' }
        else { $parts += (Get-ColorLabel $d.Colors[0]) }
    }
    if ($m.Speed) { $parts += ('速度 ' + (Get-SpeedLabel $Key $d.Speed)) }
    if ($m.Bright) { $parts += ('亮度 {0}%' -f $d.Brightness) }
    return ($parts -join ' · ')
}

function Set-Accent {
    param($Hex)
    if (-not $Hex) { $Hex = '5EE6FF' }
    $brush = ConvertTo-Brush $Hex
    $window.Resources['Accent'] = $brush.PSObject.BaseObject   # unwrap, WPF rejects PSObject wrappers
    $window.Resources['AccentColor'] = $brush.Color
    $window.Resources['AccentClear'] = [System.Windows.Media.Color]::FromArgb(0, $brush.Color.R, $brush.Color.G, $brush.Color.B)
}

function Set-Status {
    param([ValidateSet('idle', 'busy', 'warn', 'error')][string]$Kind, [string]$Text)
    $ui.StatusDot.Fill = ConvertTo-Brush (@{ idle = '34E07A'; busy = '5EE6FF'; warn = 'FFC24B'; error = 'FF5A6E' }[$Kind])
    $ui.StatusText.Text = $Text
    $ui.StatusText.ToolTip = $Text
    $ui.StatusText.Foreground = if ($Kind -eq 'error') { ConvertTo-Brush 'FF8A99' } else { $window.FindResource('Muted') }
}

function New-SwatchButton {
    param([string]$Hex, [string]$Tip)
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('Swatch')
    $b.Background = ConvertTo-Brush $Hex
    $b.ToolTip = $Tip
    $b.Tag = $Hex
    $b.HorizontalAlignment = 'Center'
    return $b
}

function Show-ColorPicker {
    param([string]$StartHex)
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml('#' + $StartHex)
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return ('{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
    }
    return $null
}

function Get-ZoneTarget {
    param([string]$Key)
    if ($script:ZoneTarget.ContainsKey($Key)) { return $script:ZoneTarget[$Key] }
    return -1   # -1 = all zones
}
$script:ZoneTarget = @{}

# ---------------------------------------------------------------- setup page (scanning / missing OpenRGB / no devices)

function Show-Setup {
    param([ValidateSet('scanning', 'noOpenRgb', 'noDevices', 'failed')][string]$Kind, [string]$Detail = '')
    $script:SetupKind = $Kind
    $ui.TabBar.Visibility = 'Collapsed'
    $ui.OverviewPage.Visibility = 'Collapsed'
    $ui.DevicePage.Visibility = 'Collapsed'
    $ui.SetupPage.Visibility = 'Visible'
    $ui.ScanButton.IsEnabled = ($Kind -ne 'scanning') -and [bool]$script:OpenRgbPath
    Set-Accent '5EE6FF'
    $ui.SetupButtons.Visibility = 'Visible'
    $ui.SetupSecondary.Visibility = 'Collapsed'
    switch ($Kind) {
        'scanning' {
            $ui.SetupGlyph.Text = [string][char]0xE895
            $ui.SetupTitle.Text = '正在偵測 RGB 裝置…'
            $ui.SetupText.Text = '透過 OpenRGB 讀取這台電腦有哪些燈光裝置，通常幾秒鐘就好。'
            $ui.SetupButtons.Visibility = 'Collapsed'
            $ui.Subtitle.Text = '偵測中'
        }
        'noOpenRgb' {
            $ui.SetupGlyph.Text = [string][char]0xE783
            $ui.SetupTitle.Text = '找不到 OpenRGB'
            $ui.SetupText.Text = "這個工具透過 OpenRGB 控制燈光。`n請先安裝 OpenRGB，或指定 OpenRGB.exe 的位置。"
            $ui.SetupPrimary.Content = '下載 OpenRGB'
            $ui.SetupSecondary.Content = '選擇 OpenRGB.exe…'
            $ui.SetupSecondary.Visibility = 'Visible'
            $ui.Subtitle.Text = '需要 OpenRGB'
        }
        'noDevices' {
            $ui.SetupGlyph.Text = [string][char]0xE7BA
            $ui.SetupTitle.Text = '沒有偵測到 RGB 裝置'
            $ui.SetupText.Text = "OpenRGB 沒有找到可以控制的燈光裝置。`n確認裝置已連接、OpenRGB 主程式沒有開著，再重新偵測一次。"
            $ui.SetupPrimary.Content = '重新偵測'
            $ui.Subtitle.Text = '沒有裝置'
        }
        'failed' {
            $ui.SetupGlyph.Text = [string][char]0xE7BA
            $ui.SetupTitle.Text = '偵測失敗'
            $ui.SetupText.Text = $Detail
            $ui.SetupPrimary.Content = '重新偵測'
            $ui.Subtitle.Text = '偵測失敗'
        }
    }
}

$ui.SetupPrimary.Add_Click({
    if ($script:SetupKind -eq 'noOpenRgb') { Start-Process 'https://openrgb.org' }
    else { Request-Scan }
})
$ui.SetupSecondary.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'OpenRGB.exe|OpenRGB.exe|程式 (*.exe)|*.exe'
    $dlg.Title = '選擇 OpenRGB.exe'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:OpenRgbPath = $dlg.FileName
        $script:State.OpenRgbPath = $dlg.FileName
        Save-State
        Set-WindowIcon
        Request-Scan
    }
})

# ---------------------------------------------------------------- background runner
# Changes update the state right away; the runner then sends the affected devices' settings
# in one hidden OpenRGB process, polled by a timer so the window never freezes.
# Requests made while busy are merged and sent once the current run ends.

$script:Busy = $false
$script:JobKind = ''
$script:ScanBase = ''
$script:PendingScan = $false
$script:PendingKeys = New-Object System.Collections.Generic.HashSet[string]
$script:Proc = $null
$script:RunStarted = [DateTime]::MinValue
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)

$script:Pulse = New-Object System.Windows.Media.Animation.DoubleAnimation
$script:Pulse.From = 0.12
$script:Pulse.To = 0.6
$script:Pulse.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
$script:Pulse.AutoReverse = $true
$script:Pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

function Request-Sync {
    param([string[]]$Keys)
    Save-State
    foreach ($k in $Keys) { [void]$script:PendingKeys.Add($k) }
    if ($script:Busy) { Set-Status 'busy' '套用中…（新的設定會接著送出）'; return }
    Start-NextJob
}

function Request-Scan {
    if (-not $script:OpenRgbPath) { Show-Setup 'noOpenRgb'; return }
    $script:PendingScan = $true
    $script:PendingKeys.Clear()
    Show-Setup 'scanning'
    Set-Status 'busy' '正在偵測裝置…'
    if (-not $script:Busy) { Start-NextJob }
}

function Start-NextJob {
    if ($script:Busy) { return }
    try {
        if ($script:PendingScan) {
            $script:PendingScan = $false
            $script:JobKind = 'scan'
            $script:ScanBase = New-ScanBase
            $script:Busy = $true
            $script:Proc = Start-OpenRgb @('--noautoconnect', '--save-profile', $script:ScanBase)
        }
        elseif ($script:PendingKeys.Count -gt 0) {
            $keys = @($script:PendingKeys)
            $script:PendingKeys.Clear()
            $script:JobKind = 'sync'
            $script:Busy = $true
            $ui.PowerGlow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:Pulse)
            Set-Status 'busy' ('正在套用：' + (($keys | ForEach-Object { $script:Catalog[$_].Label }) -join '、') + '…')
            $script:Proc = Start-OpenRgb (Get-SyncArguments $keys)
        }
        else { return }
        $script:RunStarted = Get-Date
        $script:Timer.Start()
    }
    catch { Complete-Job $false $_.Exception.Message }
}

function Complete-Job {
    param([bool]$Ok, [string]$Message)
    $script:Timer.Stop()
    $script:Proc = $null
    $script:Busy = $false
    $ui.PowerGlow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $kind = $script:JobKind
    $script:JobKind = ''

    if ($kind -eq 'scan') {
        if ($Ok) {
            try { Complete-Scan $script:ScanBase } catch { $Ok = $false; $Message = $_.Exception.Message }
        }
        if (-not $Ok) {
            Write-Log ('ERROR 偵測失敗：' + $Message)
            # Keep working with the previous device list when there is one.
            if ($script:Catalog.Count -gt 0) { Initialize-DeviceUi }
            else { Show-Setup 'failed' ("OpenRGB 偵測時出了問題：$Message`n確認 OpenRGB 主程式沒有開著，再試一次。") }
            Set-Status 'error' ('偵測失敗：' + $Message)
        }
        elseif ($script:Catalog.Count -eq 0) {
            Show-Setup 'noDevices'
            Set-Status 'warn' '沒有偵測到裝置'
        }
        else {
            Save-State
            Initialize-DeviceUi
            Set-Status 'idle' ('偵測到 {0} 個裝置 · {1}' -f $script:Catalog.Count, (Get-Date -Format 'HH:mm:ss'))
        }
    }
    elseif ($Ok) {
        Write-Log 'DONE'
        Set-Status 'idle' ('已套用 · ' + (Get-Date -Format 'HH:mm:ss'))
        Update-Overview
    }
    else {
        Write-Log ('ERROR ' + $Message)
        Set-Status 'error' ('失敗：' + $Message)
        Update-Overview
    }
    Start-NextJob
}

$script:Timer.Add_Tick({
    try {
        $p = $script:Proc
        if (-not $p) { return }
        if (-not $p.HasExited) {
            if (((Get-Date) - $script:RunStarted).TotalSeconds -gt $StepTimeoutSeconds) {
                try { $p.Kill() } catch { }
                Complete-Job $false 'OpenRGB 沒有回應（逾時）'
            }
            return
        }
        $code = $p.ExitCode
        Write-Log ('EXIT ' + $code)
        if ($code -ne 0) { Complete-Job $false "OpenRGB 回傳錯誤代碼 $code" }
        else { Complete-Job $true '' }
    }
    catch { Complete-Job $false $_.Exception.Message }
})

# ---------------------------------------------------------------- overview page

foreach ($name in $SceneInfo.Keys) {
    $sc = $SceneInfo[$name]
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.FindResource('Scene')
    $btn.Tag = $name
    $btn.Background = New-GradientBrush $sc.Colors $(if ($name -eq 'AllOff') { 1 } else { 0.9 })
    $stack = New-Object System.Windows.Controls.StackPanel
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Text = $sc.Glyph
    $glyph.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $glyph.FontSize = 20
    $glyph.Foreground = [System.Windows.Media.Brushes]::White
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $sc.Label
    $title.FontSize = 16
    $title.FontWeight = 'Bold'
    $title.Foreground = [System.Windows.Media.Brushes]::White
    $title.Margin = '0,10,0,0'
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = $sc.Sub
    $sub.FontSize = 11
    $sub.Foreground = ConvertTo-Brush 'E6EEF6'
    $sub.Margin = '0,3,0,0'
    $sub.TextWrapping = 'Wrap'
    foreach ($t in $glyph, $title, $sub) {
        $t.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 6; ShadowDepth = 0; Opacity = 0.6; Color = [System.Windows.Media.Colors]::Black }
        [void]$stack.Children.Add($t)
    }
    $btn.Content = $stack
    $btn.Add_Click({
        param($sender)
        $n = [string]$sender.Tag
        Set-Scene $n
        Write-Log ('SCENE ' + $n)
        Update-Overview
        Request-Sync @($script:Catalog.Keys)
    })
    [void]$ui.SceneGrid.Children.Add($btn)
}

foreach ($preset in $Presets) {
    $b = New-SwatchButton $preset.Hex $preset.Name
    $b.Add_Click({ param($sender) Set-AllColor ([string]$sender.Tag) })
    [void]$ui.AllSwatchGrid.Children.Add($b)
}
$allCustom = New-SwatchButton '1F2937' '自訂顏色'
$allCustom.Content = '+'; $allCustom.FontSize = 15
$allCustom.Add_Click({ $hex = Show-ColorPicker 'FFFFFF'; if ($hex) { Set-AllColor $hex } })
[void]$ui.AllSwatchGrid.Children.Add($allCustom)

function Set-AllColor {
    param([string]$Hex)
    foreach ($k in $script:Catalog.Keys) {
        $d = $script:State.Devices[$k]
        $d.On = $true
        $d.Mode = (Get-PlainMode $k).Name
        $d.Random = $false
        $d.Colors = @(1..(Get-ZoneCount $k) | ForEach-Object { $Hex })
    }
    Update-Overview
    Request-Sync @($script:Catalog.Keys)
}

# Rows on the overview page, one per detected device.
function Build-DeviceRows {
    $ui.DeviceRows.Children.Clear()
    $script:Rows = @{}
    foreach ($k in $script:Catalog.Keys) {
        $cat = $script:Catalog[$k]
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '10,10,6,10'
        foreach ($w in 'Auto', '*', 'Auto', 'Auto') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($w)
            $row.ColumnDefinitions.Add($cd)
        }
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 12; $dot.Height = 12; $dot.Margin = '0,0,14,0'; $dot.VerticalAlignment = 'Center'
        $text = New-Object System.Windows.Controls.StackPanel
        $text.VerticalAlignment = 'Center'
        $text.ToolTip = $cat.Name
        [System.Windows.Controls.Grid]::SetColumn($text, 1)
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $cat.Label; $title.FontSize = 14; $title.Foreground = $window.FindResource('TextMain')
        $sum = New-Object System.Windows.Controls.TextBlock
        $sum.FontSize = 12; $sum.Foreground = $window.FindResource('Muted'); $sum.Margin = '0,3,0,0'; $sum.TextTrimming = 'CharacterEllipsis'
        [void]$text.Children.Add($title); [void]$text.Children.Add($sum)
        $sw = New-Object System.Windows.Controls.Primitives.ToggleButton
        $sw.Style = $window.FindResource('Switch'); $sw.VerticalAlignment = 'Center'; $sw.Margin = '8,0,6,0'
        $sw.Uid = $k
        [System.Windows.Controls.Grid]::SetColumn($sw, 2)
        $go = New-Object System.Windows.Controls.Button
        $go.Style = $window.FindResource('Ghost'); $go.Content = '設定 ›'; $go.Uid = $k; $go.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($go, 3)
        foreach ($c in $dot, $text, $sw, $go) { [void]$row.Children.Add($c) }
        [void]$ui.DeviceRows.Children.Add($row)

        $sw.Add_Click({
            param($sender)
            $script:State.Devices[$sender.Uid].On = [bool]$sender.IsChecked
            Update-Overview
            Request-Sync @($sender.Uid)
        })
        $go.Add_Click({ param($sender) Show-Tab $sender.Uid })
        $script:Rows[$k] = @{ Dot = $dot; Summary = $sum; Switch = $sw }
    }
}

function Build-Tabs {
    $ui.TabGrid.Children.Clear()
    $script:Tabs = @{}
    $keys = @('All') + @($script:Catalog.Keys)
    $ui.TabGrid.Columns = [Math]::Min($keys.Count, 5)
    $ui.TabGrid.Rows = [Math]::Ceiling($keys.Count / 5)
    foreach ($k in $keys) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $window.FindResource('Seg')
        $rb.Content = if ($k -eq 'All') { '總覽' } else { $script:Catalog[$k].Label }
        if ($k -ne 'All') { $rb.ToolTip = $script:Catalog[$k].Name }
        $rb.Uid = $k
        $rb.Add_Checked({ param($sender) if (-not $script:SyncingUi) { Show-Tab $sender.Uid } })
        [void]$ui.TabGrid.Children.Add($rb)
        $script:Tabs[$k] = $rb
    }
}

function Initialize-DeviceUi {
    Build-Tabs
    Build-DeviceRows
    $ui.SetupPage.Visibility = 'Collapsed'
    $ui.TabBar.Visibility = 'Visible'
    $ui.ScanButton.IsEnabled = $true
    Show-Tab $script:State.Tab
}

function Update-Overview {
    if ($script:Catalog.Count -eq 0 -or -not $script:Rows) { return }
    $anyOn = Test-AnyOn
    foreach ($k in $script:Catalog.Keys) {
        $r = $script:Rows[$k]
        if (-not $r) { continue }
        $hex = Get-DeviceAccentHex $k
        $r.Dot.Fill = if ($hex) { ConvertTo-Brush $hex } else { $RainbowBrush }
        $r.Summary.Text = Get-DeviceSummary $k
        $r.Switch.IsChecked = $script:State.Devices[$k].On
        $r.Switch.Tag = if ($hex -and $hex -ne '4A5668') { ConvertTo-Brush $hex } else { ConvertTo-Brush '5EE6FF' }
    }
    foreach ($btn in $ui.SceneGrid.Children) {
        $active = Test-SceneActive ([string]$btn.Tag)
        $btn.BorderBrush = if ($active) { $RingBrush } else { ConvertTo-Brush '263243' }
        $btn.BorderThickness = if ($active) { 2.5 } else { 1.5 }
    }
    $total = $script:Catalog.Count
    $onCount = @($script:Catalog.Keys | Where-Object { $script:State.Devices[$_].On }).Count
    $ui.Subtitle.Text = if ($onCount -eq 0) { '全部關閉' } elseif ($onCount -eq $total) { '全部開啟' } else { '{0} / {1} 個裝置開啟' -f $onCount, $total }
    $ui.PowerTitle.Text = if ($anyOn) { '燈光開啟中' } else { '燈光已關閉' }
    $ui.PowerHint.Text = if ($anyOn) { '按電源鍵全部關燈，各裝置的設定會保留。' } else { '按電源鍵全部開燈，恢復上次的設定。' }
    if (-not $script:Busy) { $ui.PowerGlow.Opacity = if ($anyOn) { 0.45 } else { 0.08 } }

    if ($script:State.Tab -eq 'All') {
        $first = $script:Catalog.Keys | Where-Object { $script:State.Devices[$_].On } | Select-Object -First 1
        if ($first) { Set-Accent (Get-DeviceAccentHex $first) } else { Set-Accent '4A5668' }
    }
    else {
        Update-DevicePage
    }
}

# ---------------------------------------------------------------- device page

foreach ($preset in $Presets) {
    $b = New-SwatchButton $preset.Hex $preset.Name
    $b.Add_Click({ param($sender) Set-DeviceColor ([string]$sender.Tag) })
    [void]$ui.DevSwatchGrid.Children.Add($b)
}
$script:DevCustom = New-SwatchButton '1F2937' '自訂顏色'
$script:DevCustom.FontSize = 15
$script:DevCustom.Add_Click({
    $k = $script:State.Tab
    $hex = Show-ColorPicker $script:State.Devices[$k].Colors[[Math]::Max(0, (Get-ZoneTarget $k))]
    if ($hex) { Set-DeviceColor $hex }
})
[void]$ui.DevSwatchGrid.Children.Add($script:DevCustom)

function Set-DeviceColor {
    param([string]$Hex)
    $k = $script:State.Tab
    $d = $script:State.Devices[$k]
    $z = Get-ZoneTarget $k
    $cols = @($d.Colors)
    for ($i = 0; $i -lt $cols.Count; $i++) { if ($z -lt 0 -or $z -eq $i) { $cols[$i] = $Hex } }
    $d.Colors = $cols
    $d.On = $true
    $d.Random = $false
    Update-Overview
    Request-Sync @($k)
}

function Show-Tab {
    param([string]$Key)
    if ($Key -ne 'All' -and -not $script:Catalog.Contains($Key)) { $Key = 'All' }
    $script:State.Tab = $Key
    $script:SyncingUi = $true
    if ($script:Tabs[$Key]) { $script:Tabs[$Key].IsChecked = $true }
    $script:SyncingUi = $false
    if ($Key -eq 'All') {
        $ui.OverviewPage.Visibility = 'Visible'
        $ui.DevicePage.Visibility = 'Collapsed'
    }
    else {
        $ui.OverviewPage.Visibility = 'Collapsed'
        $ui.DevicePage.Visibility = 'Visible'
        $ui.DevicePage.ScrollToTop()
        Build-DevicePage
    }
    Update-Overview
    Save-State
}

# Rebuild mode and zone buttons when switching device.
function Build-DevicePage {
    $k = $script:State.Tab
    $cat = $script:Catalog[$k]
    $ui.DevTitle.Text = $cat.Label
    $ui.DevSub.Text = $cat.Sub
    $ui.DevSub.ToolTip = $cat.Name
    $ui.DevNote.Text = $cat.Note
    $ui.DevNote.Visibility = if ($cat.Note) { 'Visible' } else { 'Collapsed' }
    $ui.SpeedSlider.TickFrequency = $cat.SpeedTick

    $ui.ModeWrap.Children.Clear()
    foreach ($m in $cat.Modes) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $window.FindResource('Pill')
        $rb.GroupName = 'Mode'
        $rb.Content = $m.Label
        $rb.Uid = $m.Name
        $rb.ToolTip = if ($m.Label -ne $m.Name) { '{0}（{1}）' -f $m.Desc, $m.Name } else { $m.Desc }
        $rb.Add_Checked({
            param($sender)
            if ($script:SyncingUi) { return }
            $d = $script:State.Devices[$script:State.Tab]
            $d.Mode = $sender.Uid
            $d.On = $true
            Update-Overview
            Request-Sync @($script:State.Tab)
        })
        [void]$ui.ModeWrap.Children.Add($rb)
    }

    $ui.ZoneWrap.Children.Clear()
    if ($cat.Zones.Count -gt 1) {
        $labels = @('全部燈區') + @($cat.Zones | ForEach-Object { $_.Name })
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.Style = $window.FindResource('Pill')
            $rb.GroupName = 'Zone'
            $rb.FontSize = 12
            $rb.Tag = $i - 1
            $chip = New-Object System.Windows.Controls.StackPanel
            $chip.Orientation = 'Horizontal'
            if ($i -gt 0) {
                $zdot = New-Object System.Windows.Shapes.Ellipse
                $zdot.Width = 8; $zdot.Height = 8; $zdot.Margin = '0,0,6,0'; $zdot.VerticalAlignment = 'Center'
                [void]$chip.Children.Add($zdot)
            }
            $zlabel = New-Object System.Windows.Controls.TextBlock
            $zlabel.Text = $labels[$i]
            [void]$chip.Children.Add($zlabel)
            $rb.Content = $chip
            $rb.Add_Checked({
                param($sender)
                if ($script:SyncingUi) { return }
                $script:ZoneTarget[$script:State.Tab] = [int]$sender.Tag
                Update-DevicePage
            })
            [void]$ui.ZoneWrap.Children.Add($rb)
        }
    }
}

# Refresh the device page from the state without rebuilding it.
function Update-DevicePage {
    $k = $script:State.Tab
    if ($k -eq 'All' -or -not $script:Catalog.Contains($k)) { return }
    $cat = $script:Catalog[$k]
    $d = $script:State.Devices[$k]
    $m = Get-ModeDef $k $d.Mode
    $hex = Get-DeviceAccentHex $k
    Set-Accent $hex

    $script:SyncingUi = $true
    $ui.DevSwitch.IsChecked = $d.On
    $ui.DevSwitch.Tag = if ($hex -and $hex -ne '4A5668') { ConvertTo-Brush $hex } else { ConvertTo-Brush '5EE6FF' }
    $ui.DevSwitchText.Text = if ($d.On) { '開啟' } else { '關閉' }
    foreach ($rb in $ui.ModeWrap.Children) { $rb.IsChecked = ($rb.Uid -eq $m.Name) }
    $ui.ModeDesc.Text = $m.Desc

    $useRandom = $m.Random -and $d.Random
    $showZones = $m.PerLed -and -not $useRandom -and $cat.Zones.Count -gt 1
    if (-not $showZones) { $script:ZoneTarget[$k] = -1 }
    $ui.ColorCard.Visibility = if ($m.Color) { 'Visible' } else { 'Collapsed' }
    $ui.RandomToggle.Visibility = if ($m.Random) { 'Visible' } else { 'Collapsed' }
    $ui.RandomToggle.IsChecked = $useRandom
    $ui.RandomNote.Visibility = if ($useRandom) { 'Visible' } else { 'Collapsed' }
    $ui.DevSwatchGrid.Visibility = if ($useRandom) { 'Collapsed' } else { 'Visible' }
    $ui.ZoneWrap.Visibility = if ($showZones) { 'Visible' } else { 'Collapsed' }
    $z = Get-ZoneTarget $k
    foreach ($rb in $ui.ZoneWrap.Children) {
        $rb.IsChecked = ([int]$rb.Tag -eq $z)
        if ([int]$rb.Tag -ge 0) { $rb.Content.Children[0].Fill = ConvertTo-Brush $d.Colors[[int]$rb.Tag] }
    }

    # A swatch is ringed when every targeted zone already has that colour.
    $targets = if ($z -lt 0) { @($d.Colors) } else { @($d.Colors[$z]) }
    $same = @($targets | Select-Object -Unique)
    $current = if ($same.Count -eq 1) { $same[0] } else { $null }
    $matched = $false
    foreach ($b in $ui.DevSwatchGrid.Children) {
        if ($b -eq $script:DevCustom) { continue }
        $sel = $d.On -and $current -and ($b.Tag -eq $current)
        if ($sel) { $matched = $true }
        $b.BorderBrush = if ($sel) { $RingBrush } else { $Transparent }
    }
    if ($d.On -and $current -and -not $matched) {
        $script:DevCustom.Background = ConvertTo-Brush $current
        $script:DevCustom.BorderBrush = $RingBrush
        $script:DevCustom.Content = ''
    }
    else {
        $script:DevCustom.Background = ConvertTo-Brush '1F2937'
        $script:DevCustom.BorderBrush = $Transparent
        $script:DevCustom.Content = '+'
    }

    $ui.SpeedCard.Visibility = if ($m.Speed) { 'Visible' } else { 'Collapsed' }
    $ui.SpeedSlider.Value = $d.Speed
    $ui.SpeedText.Text = Get-SpeedLabel $k $d.Speed
    $ui.BrightCard.Visibility = if ($m.Bright) { 'Visible' } else { 'Collapsed' }
    $ui.BrightSlider.Value = $d.Brightness
    $ui.BrightText.Text = '{0}%' -f $d.Brightness
    $script:SyncingUi = $false
}

# ---------------------------------------------------------------- events

$ui.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$ui.CloseButton.Add_Click({ $window.Close() })
$ui.MinButton.Add_Click({ $window.WindowState = 'Minimized' })
$ui.ScanButton.Add_Click({ Request-Scan })
$ui.LogButton.Add_Click({
    if (Test-Path -LiteralPath $LogPath) { Start-Process notepad.exe -ArgumentList ('"' + $LogPath + '"') }
    else { Set-Status 'warn' '目前還沒有紀錄檔' }
})

$ui.PowerButton.Add_Click({
    Set-AllPower (-not (Test-AnyOn))
    Update-Overview
    Request-Sync @($script:Catalog.Keys)
})

$ui.DevSwitch.Add_Click({
    $k = $script:State.Tab
    $script:State.Devices[$k].On = [bool]$ui.DevSwitch.IsChecked
    Update-Overview
    Request-Sync @($k)
})

$ui.RandomToggle.Add_Click({
    $k = $script:State.Tab
    $d = $script:State.Devices[$k]
    $d.Random = [bool]$ui.RandomToggle.IsChecked
    $d.On = $true
    Update-Overview
    Request-Sync @($k)
})

$ui.SpeedSlider.Add_ValueChanged({
    if ($script:SyncingUi) { return }
    $k = $script:State.Tab
    $script:State.Devices[$k].Speed = [int]$ui.SpeedSlider.Value
    $ui.SpeedText.Text = Get-SpeedLabel $k ([int]$ui.SpeedSlider.Value)
})
$ui.BrightSlider.Add_ValueChanged({
    if ($script:SyncingUi) { return }
    $script:State.Devices[$script:State.Tab].Brightness = [int]$ui.BrightSlider.Value
    $ui.BrightText.Text = '{0}%' -f [int]$ui.BrightSlider.Value
})
# Sliders send their value when released, not on every pixel of the drag.
$sliderDone = {
    if ($script:SyncingUi) { return }
    $k = $script:State.Tab
    $script:State.Devices[$k].On = $true
    Update-Overview
    Request-Sync @($k)
}
foreach ($s in $ui.SpeedSlider, $ui.BrightSlider) {
    $s.Add_PreviewMouseLeftButtonUp($sliderDone)
    $s.Add_KeyUp($sliderDone)
}

$window.Add_KeyDown({
    param($sender, $e)
    $key = [string]$e.Key
    if ($key -eq 'Escape') { $window.Close() }
    elseif ($script:Catalog.Count -eq 0 -or $ui.SetupPage.Visibility -eq 'Visible') { return }
    elseif ($key -eq 'Space' -and $script:State.Tab -eq 'All') {
        Set-AllPower (-not (Test-AnyOn)); Update-Overview; Request-Sync @($script:Catalog.Keys)
        $e.Handled = $true
    }
    elseif ($key -match '^(D|NumPad)([1-9])$') {
        $keys = @('All') + @($script:Catalog.Keys)
        $n = [int]$Matches[2] - 1
        if ($n -lt $keys.Count) { Show-Tab $keys[$n] }
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show('燈光還在套用中，確定要關閉嗎？', 'RGB 光控中心', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $e.Cancel = $true }
    }
})

# ---------------------------------------------------------------- start

Set-WindowIcon
if (-not $script:OpenRgbPath) {
    Show-Setup 'noOpenRgb'
    Set-Status 'warn' '需要先安裝 OpenRGB'
}
elseif (Import-DeviceCache) {
    Initialize-DeviceUi
    if (Get-Process -Name 'OpenRGB' -ErrorAction SilentlyContinue) {
        Set-Status 'warn' 'OpenRGB 主程式正在執行，可能會蓋掉這裡的設定'
    }
    else {
        Set-Status 'idle' '就緒 · 數字鍵切換分頁，空白鍵全部開關'
    }
}
else {
    Request-Scan
}
[void]$window.ShowDialog()
$script:Mutex.ReleaseMutex()

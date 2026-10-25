# Windows PowerShell 5.1 / PowerShell 7. Save as UTF-8 with BOM.
$script:ProjectDir = Split-Path $PSScriptRoot -Parent
$script:RuntimeDir = Join-Path $script:ProjectDir 'scrcpy'
$script:Adb = Join-Path $script:RuntimeDir 'adb.exe'
$script:Cache = Join-Path $PSScriptRoot '.last_device'

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW quoting; never pass user input through cmd /c.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-Adb {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 10)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:Adb
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        # Drain both streams concurrently, including when adb produces many lines.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill(); $process.WaitForExit() } catch { }
            throw "ADB 操作超时（${TimeoutSeconds} 秒）：$($Arguments[0])。请检查连接或 5037 端口。"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Text = ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()).Trim()
        }
    } finally { $process.Dispose() }
}

function Assert-AdbResult {
    param($Result, [string]$Message)
    if ($Result.ExitCode -ne 0) { throw "$Message`n$($Result.Text)" }
}

function ConvertTo-Endpoint {
    param([string]$Value)
    $match = [regex]::Match($Value.Trim(), '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})(?::([0-9]{1,5}))?$')
    if (-not $match.Success) { throw '地址格式应为 IPv4:端口，例如 192.168.2.40:42215。省略端口时使用 5555。' }
    $parts = @($match.Groups[1].Value.Split('.') | ForEach-Object {
        $n = [int]$_
        if ($n -gt 255) { throw 'IP 地址每段必须在 0 到 255 之间。' }
        $n
    })
    $port = 5555
    if ($match.Groups[2].Success) { $port = [int]$match.Groups[2].Value }
    if ($port -lt 1 -or $port -gt 65535) { throw '端口必须在 1 到 65535 之间。' }
    return ($parts -join '.') + ':' + $port
}

function ConvertFrom-DeviceList {
    param([string]$Text)
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -notmatch '^(\S+)\s+(device|offline|unauthorized|recovery|sideload|bootloader|no permissions)(?:\s|$)') { continue }
        $serial = $Matches[1]
        $state = $Matches[2]
        $kind = 'USB'
        if ($serial -match '^emulator-[0-9]+$') { $kind = 'Emulator' }
        elseif ($serial.Contains(':') -or $serial -match '\._adb-tls-(connect|pairing)\._tcp\.?$') { $kind = 'Wireless' }
        $model = ''
        if ($line -match '\bmodel:(\S+)') { $model = $Matches[1] }
        [pscustomobject]@{ Serial = $serial; State = $state; Kind = $kind; Model = $model }
    }
}

function Get-Devices {
    $result = Invoke-Adb -Arguments @('devices', '-l')
    Assert-AdbResult $result '无法查询设备。'
    ConvertFrom-DeviceList $result.Text
}

function Select-Device {
    param([object[]]$Devices)
    $online = @($Devices | Where-Object State -eq 'device')
    if ($online.Count -eq 0) { throw '没有可用设备。offline 请重连；unauthorized 请解锁手机并允许 USB 调试。' }
    if ($online.Count -eq 1) { return $online[0] }
    for ($i = 0; $i -lt $online.Count; $i++) {
        Write-Host ('  {0}. {1}  {2} [{3}]' -f ($i + 1), $online[$i].Serial, $online[$i].Model, $online[$i].Kind)
    }
    while ($true) {
        $answer = Read-Host '请选择序号（输入 q 取消）'
        if ($answer -eq 'q') { throw '已取消。' }
        $number = 0
        if ($answer -match '^[0-9]+$' -and [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $online.Count) {
            return $online[$number - 1]
        }
        Write-Host '序号无效，请重新选择。'
    }
}

function Read-CachedEndpoint {
    if (Test-Path -LiteralPath $script:Cache -PathType Leaf) {
        try { return ConvertTo-Endpoint ([IO.File]::ReadAllText($script:Cache)) }
        catch { Write-Host '[提示] 上次地址缓存无效，已忽略。' }
    }
    return $null
}

function Save-Endpoint {
    param([string]$Endpoint)
    try { [IO.File]::WriteAllText($script:Cache, (ConvertTo-Endpoint $Endpoint), [Text.Encoding]::ASCII) }
    catch { Write-Host ('[提示] 无法保存地址缓存：' + $_.Exception.Message) }
}

function Connect-Endpoint {
    param([string]$Endpoint)
    $Endpoint = ConvertTo-Endpoint $Endpoint
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $device = @(Get-Devices | Where-Object { $_.Serial -eq $Endpoint -and $_.State -eq 'device' })
        if ($device.Count -gt 0) { Save-Endpoint $Endpoint; return $device[0] }
        Write-Host "正在连接 $Endpoint（第 $attempt 次）..."
        try {
            $result = Invoke-Adb -Arguments @('connect', $Endpoint) -TimeoutSeconds 8
            if ($result.Text) { Write-Host $result.Text }
        } catch {
            Write-Host $_.Exception.Message
            if ($attempt -lt 2) { continue }
            break
        }
        # adb connect may return 0 even on failure. Verify the actual device state.
        for ($poll = 0; $poll -lt 3; $poll++) {
            $device = @(Get-Devices | Where-Object { $_.Serial -eq $Endpoint -and $_.State -eq 'device' })
            if ($device.Count -gt 0) { Save-Endpoint $Endpoint; return $device[0] }
            if ($poll -lt 2) { Start-Sleep -Milliseconds 300 }
        }
    }
    throw "无法连接 $Endpoint。`n确认手机与电脑处于同一局域网，并使用无线调试首页的连接端口。`nAndroid 无线调试的端口可能变化；配对端口不能用于连接。若未配对，请运行 5.无线调试配对.bat。"
}

function Wait-UsbDevice {
    param([int]$TimeoutSeconds = 20)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $usb = @(Get-Devices | Where-Object Kind -eq 'USB')
        if (@($usb | Where-Object State -eq 'device').Count -gt 0) { return Select-Device $usb }
        if (@($usb | Where-Object State -eq 'unauthorized').Count -gt 0) { Write-Host '请在手机上允许 USB 调试。' }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds 500
    } while ($true)
    throw "等待 USB 设备超时（${TimeoutSeconds} 秒）。请检查数据线、USB 调试授权和驱动。"
}

function Assert-Dependencies {
    param([bool]$Mirror)
    $required = @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')
    if ($Mirror) {
        $required += @('scrcpy.exe', 'scrcpy-server')
    }
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RuntimeDir $_) -PathType Leaf) })
    if ($Mirror) {
        # Match library families so official upgrades can change DLL version suffixes.
        foreach ($pattern in @('SDL*.dll', 'avcodec-*.dll', 'avformat-*.dll', 'avutil-*.dll', 'swresample-*.dll', 'libusb-*.dll')) {
            if (@(Get-ChildItem -LiteralPath $script:RuntimeDir -Filter $pattern -File -ErrorAction SilentlyContinue).Count -eq 0) { $missing += $pattern }
        }
    }
    if ($missing.Count) { throw ('scrcpy 文件夹缺少必要文件：' + ($missing -join ', ') + '。请将官方压缩包内的全部文件解压到该文件夹。') }
}

function Start-Mirror {
    param($Device, [string[]]$ExtraArguments)
    $env:ADB = $script:Adb
    $env:SCRCPY_SERVER_PATH = Join-Path $script:RuntimeDir 'scrcpy-server'
    $env:SCRCPY_ICON_DIR = $script:RuntimeDir
    $nativeArgs = @('-s', $Device.Serial)
    if ($Device.Kind -eq 'USB') { $nativeArgs += '--stay-awake' }
    else { $nativeArgs += '--keep-active' }
    $nativeArgs += $ExtraArguments
    Write-Host ('正在投屏：' + $Device.Serial + '  ' + $Device.Model)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $script:RuntimeDir 'scrcpy.exe'
    $info.Arguments = ($nativeArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    # Keep caller's working directory: relative --record / --push-target paths stay meaningful.
    $process = [Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function Enable-UsbWireless {
    param([int]$TimeoutSeconds)
    $device = Wait-UsbDevice $TimeoutSeconds
    # Read the address before restarting adbd; the USB transport may disappear afterwards.
    $result = Invoke-Adb -Arguments @('-s', $device.Serial, 'shell', 'ip', '-o', '-4', 'addr', 'show', 'scope', 'global')
    Assert-AdbResult $result '无法读取手机网络地址。'
    $ip = $null
    foreach ($line in ($result.Text -split '\r?\n')) {
        if ($line -match '^\d+:\s+(?:wlan\S*|wifi\S*)\s+.*\binet\s+([0-9.]+)/') { $ip = $Matches[1]; break }
    }
    if (-not $ip) { $ip = Read-Host '未找到 Wi-Fi 地址，请输入手机 Wi-Fi IPv4 地址' }
    $endpoint = ConvertTo-Endpoint ($ip + ':5555')
    $result = Invoke-Adb -Arguments @('-s', $device.Serial, 'tcpip', '5555')
    Assert-AdbResult $result '切换 TCP/IP 模式失败。'
    Write-Host $result.Text
    Start-Sleep -Milliseconds 800
    [void](Connect-Endpoint $endpoint)
    Write-Host "[成功] 已验证无线连接 $endpoint，现在可拔掉数据线并运行 3.无线直接投屏.bat。"
}

function Stop-LocalAdb {
    # Do not terminate clients from another scrcpy installation or arbitrary port owners.
    $exe = Join-Path $script:RuntimeDir 'scrcpy.exe'
    foreach ($process in @(Get-Process -Name scrcpy -ErrorAction SilentlyContinue)) {
        if ($process.Path -eq $exe) { Stop-Process -Id $process.Id -ErrorAction Stop }
    }
    $result = Invoke-Adb -Arguments @('kill-server')
    Assert-AdbResult $result '停止 ADB 服务失败。'
    Write-Host '[完成] 本目录的投屏窗口已关闭，ADB 服务已停止。共享此 ADB 服务的其他工具也会断开连接。'
}

function Invoke-ScrcpyScripts {
    param([string[]]$CliArguments)
    $action = 'mirror'
    if ($CliArguments.Count -gt 0) { $action = $CliArguments[0] }
    if ($action -notin @('console', 'stop', 'setup', 'connect', 'mirror', 'usb', 'pair')) { throw "未知操作：$action" }
    $script:NoPause = $env:SCRCPY_SCRIPTS_NO_PAUSE -eq '1'
    $endpoint = $null
    $usbTimeout = 20
    $extra = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 1; $i -lt $CliArguments.Count; $i++) {
        switch -CaseSensitive ($CliArguments[$i]) {
            '--no-pause' { $script:NoPause = $true }
            '--address' {
                $i++
                if ($i -ge $CliArguments.Count) { throw '--address 缺少地址。' }
                $endpoint = ConvertTo-Endpoint $CliArguments[$i]
            }
            '--usb-timeout' {
                $i++
                if ($i -ge $CliArguments.Count -or $CliArguments[$i] -notmatch '^[0-9]{1,3}$') { throw '--usb-timeout 应为 0 到 300 的秒数。' }
                $usbTimeout = [int]$CliArguments[$i]
                if ($usbTimeout -gt 300) { throw '--usb-timeout 最大为 300 秒。' }
            }
            default { $extra.Add($CliArguments[$i]) }
        }
    }
    if ($extra.Count -and $action -notin @('connect', 'mirror', 'usb')) { throw '此操作不接受额外参数。' }
    if ($endpoint -and $action -notin @('connect', 'mirror', 'pair')) { throw '--address 只适用于无线连接、无线投屏或配对。' }
    Assert-Dependencies ($action -in @('connect', 'mirror', 'usb'))
    if ($action -eq 'stop') { Stop-LocalAdb; return 0 }
    Assert-AdbResult (Invoke-Adb -Arguments @('start-server')) '启动 ADB 服务失败。'
    if ($action -eq 'console') {
        Write-Host ((Invoke-Adb -Arguments @('devices', '-l')).Text)
        # cmd's working directory and PATH both point to this installation.
        $env:PATH = $script:RuntimeDir + ';' + $env:PATH
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /k'
        $info.WorkingDirectory = $script:RuntimeDir
        $info.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($info)
        return 0
    }
    if ($action -eq 'setup') { Enable-UsbWireless $usbTimeout; return 0 }
    if ($action -eq 'pair') {
        Write-Host '手机：开发者选项 → 无线调试 → 使用配对码配对设备。'
        if (-not $endpoint) { $endpoint = ConvertTo-Endpoint (Read-Host '请输入配对窗口中的 IPv4:配对端口') }
        $code = Read-Host '请输入六位配对码'
        if ($code -notmatch '^[0-9]{6}$') { throw '配对码必须为六位数字。' }
        $result = Invoke-Adb -Arguments @('pair', $endpoint, $code) -TimeoutSeconds 30
        Assert-AdbResult $result '配对失败。请保持手机配对窗口打开，并确认端口和配对码。'
        Write-Host $result.Text
        Write-Host '配对后运行 2.启动adb无线连接并投屏.bat，输入无线调试首页的连接端口。'
        return 0
    }
    if ($action -eq 'usb') { $device = Wait-UsbDevice $usbTimeout }
    elseif ($endpoint) { $device = Connect-Endpoint $endpoint }
    elseif ($action -eq 'connect') {
        $cached = Read-CachedEndpoint
        if ($cached) { Write-Host "直接回车可使用上次地址：$cached" }
        Write-Host 'Android 无线调试请使用首页的连接端口；USB 开启的 TCP/IP 模式默认 5555。'
        $answer = Read-Host '请输入手机 IPv4:连接端口'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $cached }
        if (-not $answer) { throw '未输入连接地址。' }
        $device = Connect-Endpoint (ConvertTo-Endpoint $answer)
    } else {
        $wireless = @(Get-Devices | Where-Object Kind -eq 'Wireless')
        if (@($wireless | Where-Object State -eq 'device').Count -gt 0) { $device = Select-Device $wireless }
        else {
            $cached = Read-CachedEndpoint
            if (-not $cached) { throw '没有在线无线设备或有效缓存。请运行 2.启动adb无线连接并投屏.bat。' }
            $device = Connect-Endpoint $cached
        }
    }
    if ($device.Kind -eq 'Wireless' -and $device.Serial -match '^[0-9.]+:[0-9]+$') { Save-Endpoint $device.Serial }
    return Start-Mirror $device $extra.ToArray()
}

# Dot-sourcing loads functions for regression checks without connecting to a phone.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $script:NoPause = $env:SCRCPY_SCRIPTS_NO_PAUSE -eq '1' -or $args -contains '--no-pause'
    $oldOutputEncoding = [Console]::OutputEncoding
    $oldInputEncoding = [Console]::InputEncoding
    $exitCode = 1
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        $exitCode = Invoke-ScrcpyScripts -CliArguments @($args)
        if ($exitCode -ne 0) { Write-Host "[错误] scrcpy 退出码：$exitCode。请查看上方输出。" }
    } catch { Write-Host ('[错误] ' + $_.Exception.Message) }
    finally {
        if (-not $script:NoPause -and -not [Console]::IsInputRedirected -and ($exitCode -ne 0 -or $args[0] -in @('setup', 'pair', 'stop'))) {
            [void](Read-Host '按回车关闭窗口')
        }
        [Console]::OutputEncoding = $oldOutputEncoding
        [Console]::InputEncoding = $oldInputEncoding
    }
    exit $exitCode
}

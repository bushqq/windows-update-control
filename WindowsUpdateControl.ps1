[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Restore', 'Status')]
    [string]$Action = 'Status',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$backupDirectory = Join-Path $env:ProgramData 'WindowsUpdateControl'
$backupFile = Join-Path $backupDirectory 'original-settings.json'
$serviceNames = @('wuauserv', 'UsoSvc')

function Invoke-ServiceConfig([string]$Name, [int]$StartValue) {
    $mode = switch ($StartValue) {
        2 { 'auto' }
        3 { 'demand' }
        4 { 'disabled' }
        default { throw "不支持的服务启动类型：$StartValue" }
    }
    $message = & "$env:SystemRoot\System32\sc.exe" config $Name start= $mode 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "服务 $Name 配置失败：$($message -join ' ')"
    }
}

function Read-OriginalSettings {
    $settings = Get-Content -LiteralPath $backupFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $machineId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    if ($settings.Version -ne 1 -or $settings.MachineId -ne $machineId) {
        throw '备份不属于当前电脑，或格式不受支持。为避免错误恢复，已停止。'
    }
    $names = @($settings.Services | ForEach-Object { $_.Name })
    if ($names.Count -lt 1 -or $names.Count -gt 2 -or $names -notcontains 'wuauserv' -or
        @($names | Select-Object -Unique).Count -ne $names.Count) {
        throw '备份中的服务列表无效。'
    }
    foreach ($entry in $settings.Services) {
        if ($entry.Name -notin $serviceNames -or $entry.Start -notin @(2, 3, 4) -or
            $entry.WasRunning -isnot [bool] -or $entry.DelayPresent -isnot [bool] -or
            ($entry.DelayPresent -and $entry.DelayValue -notin @(0, 1))) {
            throw '备份中的服务配置无效。'
        }
    }
    if ($settings.Policy.Present -isnot [bool] -or
        ($settings.Policy.Present -and $settings.Policy.Value -notin @(0, 1))) {
        throw '备份中的更新策略无效。'
    }
    return $settings
}

function Save-OriginalSettings {
    if (Test-Path -LiteralPath $backupFile) {
        $null = Read-OriginalSettings
        Write-Host '沿用首次备份，不覆盖原配置。'
        return
    }
    $entries = foreach ($name in $serviceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $service) { continue }
        $key = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        $start = [int]$key.GetValue('Start')
        if ($start -notin @(2, 3, 4)) { throw "服务 $name 的配置异常，已停止。" }
        $hasDelay = $key.GetValueNames() -contains 'DelayedAutoStart'
        if ($hasDelay -and [int]$key.GetValue('DelayedAutoStart') -notin @(0, 1)) {
            throw "服务 $name 的延迟启动配置异常，已停止。"
        }
        [pscustomobject]@{
            Name = $name
            Start = $start
            WasRunning = ($service.Status -eq 'Running')
            DelayPresent = $hasDelay
            DelayValue = $(if ($hasDelay) { [int]$key.GetValue('DelayedAutoStart') } else { 0 })
        }
    }
    if (@($entries.Name) -notcontains 'wuauserv') { throw '找不到 Windows Update 服务。' }
    $policyExists = $false
    $policyValue = 0
    if (Test-Path $policyPath) {
        $key = Get-Item $policyPath
        $policyExists = $key.GetValueNames() -contains 'NoAutoUpdate'
        if ($policyExists) {
            if ($key.GetValueKind('NoAutoUpdate') -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
                throw '现有更新策略的数据类型异常，已停止。'
            }
            $policyValue = [int]$key.GetValue('NoAutoUpdate')
            if ($policyValue -notin @(0, 1)) { throw '现有更新策略的值异常，已停止。' }
        }
    }
    $settings = [pscustomobject]@{
        Version = 1
        MachineId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
        CreatedAt = (Get-Date).ToString('o')
        Services = @($entries)
        Policy = [pscustomobject]@{ Present = $policyExists; Value = $policyValue }
    }
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$backupFile.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$backupFile.tmp" -Destination $backupFile
    Write-Host "原配置已备份：$backupFile"
}

function Stop-UpdateService([string]$Name) {
    $service = Get-Service $Name
    if ($service.Status -eq 'Stopped') { return $true }
    $null = & "$env:SystemRoot\System32\sc.exe" stop $Name 2>&1
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $service.Refresh()
        if ($service.Status -eq 'Stopped') { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Show-Status {
    Get-Service -Name $serviceNames -ErrorAction SilentlyContinue |
        Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-Host
    if (Test-Path $policyPath) {
        $value = (Get-Item $policyPath).GetValue('NoAutoUpdate', $null)
        Write-Host "NoAutoUpdate：$value"
    }
    Write-Host "原配置备份存在：$(Test-Path -LiteralPath $backupFile)"
}

$exitCode = 0
try {
    if ($Action -eq 'Status') {
        Show-Status
    } else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Host '正在请求管理员权限，请在弹出的窗口中选择“是”。'
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $PSCommandPath, $Action
            if ($NoPause) { $arguments += ' -NoPause' }
            $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            $NoPause = $true
            exit $process.ExitCode
        }
        $os = Get-CimInstance Win32_OperatingSystem
        $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        if ([int]$os.BuildNumber -lt 22000 -or $os.ProductType -ne 1 -or $edition -ne 'CoreCountrySpecific') {
            throw '此脚本针对 Windows 11 家庭中文版制作；当前系统不匹配，已停止。'
        }

        if ($Action -eq 'Disable') {
            Save-OriginalSettings
            Invoke-ServiceConfig 'wuauserv' 4
            New-Item -Path $policyPath -Force | Out-Null
            New-ItemProperty -Path $policyPath -Name 'NoAutoUpdate' -PropertyType DWord -Value 1 -Force | Out-Null
            $stopped = Stop-UpdateService 'wuauserv'
            if (Get-Service 'UsoSvc' -ErrorAction SilentlyContinue) {
                try {
                    Invoke-ServiceConfig 'UsoSvc' 4
                    if (-not (Stop-UpdateService 'UsoSvc')) {
                        Write-Warning '更新协调服务尚未停止，重启后生效。'
                    }
                } catch {
                    Write-Warning "系统保护阻止修改更新协调服务；Windows Update 服务已禁用。$($_.Exception.Message)"
                }
            }
            $start = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv').Start
            if ($start -ne 4) { throw 'Windows Update 服务启动配置校验失败，请查看错误并重试。' }
            if ($stopped) {
                Write-Host "`n已关闭 Windows 自动更新。" -ForegroundColor Green
            } else {
                Write-Host "`n已禁用更新服务，但当前服务尚未停止。请重启电脑使设置完整生效。" -ForegroundColor Yellow
            }
            Write-Host '需要恢复时，双击 RestoreUpdates.cmd。大型系统升级可能重新开启更新。'
        } else {
            if (-not (Test-Path -LiteralPath $backupFile)) {
                throw '找不到原配置备份。没有擅自写入默认值；如果尚未运行关闭脚本，无需恢复。'
            }
            $settings = Read-OriginalSettings
            $failed = @()
            foreach ($entry in $settings.Services) {
                try {
                    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)"
                    $currentStart = (Get-ItemProperty $serviceKey).Start
                    if ($currentStart -ne $entry.Start) {
                        Invoke-ServiceConfig $entry.Name ([int]$entry.Start)
                    }
                    $key = Get-Item $serviceKey
                    $delayExists = $key.GetValueNames() -contains 'DelayedAutoStart'
                    if ($entry.DelayPresent) {
                        if (-not $delayExists -or $key.GetValue('DelayedAutoStart') -ne $entry.DelayValue) {
                            New-ItemProperty -Path $serviceKey -Name 'DelayedAutoStart' -PropertyType DWord -Value ([int]$entry.DelayValue) -Force | Out-Null
                        }
                    } elseif ($delayExists) {
                        Remove-ItemProperty -Path $serviceKey -Name 'DelayedAutoStart'
                    }
                    if ($entry.WasRunning -and $entry.Start -ne 4) {
                        try { Start-Service $entry.Name } catch { Write-Warning "服务 $($entry.Name) 暂时无法启动，请重启电脑。" }
                    }
                } catch {
                    $failed += $entry.Name
                    Write-Warning $_.Exception.Message
                }
            }
            if ($settings.Policy.Present) {
                New-Item -Path $policyPath -Force | Out-Null
                New-ItemProperty -Path $policyPath -Name 'NoAutoUpdate' -PropertyType DWord -Value ([int]$settings.Policy.Value) -Force | Out-Null
            } elseif (Test-Path $policyPath) {
                if ((Get-Item $policyPath).GetValueNames() -contains 'NoAutoUpdate') {
                    Remove-ItemProperty -Path $policyPath -Name 'NoAutoUpdate'
                }
            }
            if ($failed.Count -gt 0) {
                throw "部分配置未恢复：$($failed -join ', ')。备份已保留，请重启后再次运行恢复脚本。"
            }
            Remove-Item -LiteralPath $backupFile
            Write-Host "`n已恢复关闭脚本运行前的配置。建议重启电脑后再检查 Windows 更新。" -ForegroundColor Green
        }
        Show-Status
    }
} catch {
    $exitCode = 1
    Write-Host "`n操作未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '若之前已有部分设置生效，可运行 RestoreUpdates.cmd 恢复；原配置备份会保留到恢复成功。'
} finally {
    if (-not $NoPause) { $null = Read-Host '按回车关闭窗口' }
}
exit $exitCode

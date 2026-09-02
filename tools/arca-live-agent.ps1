$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'AbeyyN/OpenWRT---AbeyyWRT'
$Issue = 10
$Key = Join-Path $env:USERPROFILE '.ssh\arca_bridge'
$Targets = @('192.168.1.1','100.85.154.66')

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host ' ABEYYWRT ARCA LIVE AGENT V2' -ForegroundColor Cyan
Write-Host ' LAN first + Tailscale fallback' -ForegroundColor Cyan
Write-Host ' Stock-QMI destructive commands HARD BLOCKED' -ForegroundColor Green
Write-Host ' GitHub Issue control channel' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan

if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) missing.'
}

& gh auth status --hostname github.com 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

if (-not (Test-Path $Key)) {
    throw "Arca SSH key missing: $Key"
}

Get-Process -Name 'ssh' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host 'Installing Posh-SSH / SSH.NET once...' -ForegroundColor Yellow
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
    Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}
Import-Module Posh-SSH -Force

$Secure = New-Object System.Security.SecureString
$Cred = New-Object System.Management.Automation.PSCredential('root', $Secure)
$LastId = -1
$LastPollWarning = ''

function Post-AgentResult {
    param(
        [int]$Id,
        [string]$Status,
        [string]$Text
    )

    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt 48000) {
        $Text = $Text.Substring(0,48000) + "`n...[TRUNCATED]"
    }

    $Body = @"
### Arca agent V2 result #$Id — $Status

``````text
$Text
``````
"@

    $Tmp = Join-Path $env:TEMP 'arca-agent-result.md'
    [IO.File]::WriteAllText($Tmp, $Body, [Text.UTF8Encoding]::new($false))
    & gh issue comment $Issue --repo $Repo --body-file $Tmp 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to post result to GitHub Issue.' }
}

function Get-AgentCommand {
    $Body = (& gh issue view $Issue --repo $Repo --json body --jq '.body' 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Body)) { return $null }

    $mId = [regex]::Match($Body, '(?m)^id=(\d+)\s*$')
    $mTimeout = [regex]::Match($Body, '(?m)^timeout=(\d+)\s*$')
    $mCmd = [regex]::Match($Body, '(?m)^command_b64=([A-Za-z0-9+/=]+)\s*$')
    if (-not $mId.Success -or -not $mCmd.Success) { return $null }

    $Id = [int]$mId.Groups[1].Value
    $Timeout = 30
    if ($mTimeout.Success) { $Timeout = [Math]::Max(5,[Math]::Min(180,[int]$mTimeout.Groups[1].Value)) }
    $Command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mCmd.Groups[1].Value))

    [pscustomobject]@{
        id = $Id
        timeout = $Timeout
        command = $Command
    }
}

function Test-ArcaCommandSafety {
    param([string]$Command)

    # AbeyyWRT modem ownership is immutable by policy:
    # RG500Q-EA -> quectel-CM-M -> RAW-IP wwan0.  Stock netifd/uqmi must never
    # be allowed to start a competing data session or power-cycle the SIM.
    $Forbidden = @(
        '(?is)uci\s+(?:-q\s+)?set\s+network\.wwan\.proto\s*=\s*["'']?qmi',
        '(?im)(^|[;&|]\s*)ifup\s+wwan(?:\s|$)',
        '(?im)(^|\s)uqmi(?:\s|$)',
        '(?i)qmi_wwan/(?:un)?bind',
        '(?i)--uim-power-(?:off|on)'
    )
    foreach ($Pattern in $Forbidden) {
        if ($Command -match $Pattern) {
            return "BLOCKED_BY_ARCA_MODEM_SAFETY_GATE pattern=$Pattern"
        }
    }
    return $null
}

function Invoke-ArcaCommand {
    param([string]$Command,[int]$Timeout)

    $Safety = Test-ArcaCommandSafety -Command $Command
    if ($Safety) { throw $Safety }

    $Errors = @()
    foreach ($Target in $Targets) {
        $Session = $null
        try {
            Write-Host "Trying ARCA target $Target..." -ForegroundColor DarkCyan
            $Session = @(New-SSHSession -ComputerName $Target -Credential $Cred -KeyFile $Key -AcceptKey -Force -ConnectionTimeout 8 -ErrorAction Stop)[0]
            if ($null -eq $Session -or -not $Session.Connected) {
                throw 'SSH.NET did not establish a session.'
            }
            $Result = Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $Timeout -ErrorAction Stop
            $Out = @("ARCA_TARGET=$Target")
            if ($Result.Output) { $Out += $Result.Output }
            if ($Result.Error) { $Out += ($Result.Error | ForEach-Object { "STDERR: $_" }) }
            $Out += "REMOTE_EXIT=$($Result.ExitStatus)"
            return ($Out -join "`n")
        }
        catch {
            $Errors += "$Target => $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $Session) {
                Remove-SSHSession -SSHSession $Session -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    throw ('All ARCA targets failed: ' + ($Errors -join ' | '))
}

Write-Host 'Agent V2 online. Keep this PowerShell window open.' -ForegroundColor Green
Write-Host 'No more router commands need to be typed manually.' -ForegroundColor Green
Write-Host 'Safety: stock QMI/uqmi/SIM power-cycle commands are rejected.' -ForegroundColor Green
Post-AgentResult -Id 0 -Status 'ONLINE' -Text "Agent V2 started on $env:COMPUTERNAME as $env:USERNAME. Targets=$($Targets -join ','). Stock-QMI safety gate=ON. Key=$Key"

while ($true) {
    try {
        $Job = Get-AgentCommand
        $LastPollWarning = ''
        if ($null -ne $Job) {
            $Id = [int]$Job.id
            if ($Id -ne $LastId) {
                $LastId = $Id
                if ([string]$Job.command -eq '__STOP__') {
                    Post-AgentResult -Id $Id -Status 'STOPPED' -Text 'Agent stop requested.'
                    break
                }

                $Timeout = [int]$Job.timeout
                Write-Host "Executing command #$Id (timeout ${Timeout}s)..." -ForegroundColor Cyan

                try {
                    $Text = Invoke-ArcaCommand -Command ([string]$Job.command) -Timeout $Timeout
                    Post-AgentResult -Id $Id -Status 'DONE' -Text $Text
                    Write-Host "Command #$Id done." -ForegroundColor Green
                }
                catch {
                    $Msg = $_ | Out-String
                    try { Post-AgentResult -Id $Id -Status 'ERROR' -Text $Msg } catch {}
                    Write-Host "Command #$Id error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    catch {
        $Msg = $_.Exception.Message
        if ($Msg -ne $LastPollWarning) {
            Write-Host "Agent poll warning: $Msg" -ForegroundColor DarkYellow
            $LastPollWarning = $Msg
        }
    }
    Start-Sleep -Seconds 3
}

Write-Host 'Arca Live Agent V2 stopped.' -ForegroundColor Yellow

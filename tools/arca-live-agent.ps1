$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = 'AbeyyN/OpenWRT---AbeyyWRT'
$Issue = 10
$CommandPath = 'ops/arca-agent-command.json'
$Key = Join-Path $env:USERPROFILE '.ssh\arca_bridge'

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host ' ABEYYWRT ARCA LIVE AGENT' -ForegroundColor Cyan
Write-Host ' Direct laptop -> 192.168.1.1' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan

if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) missing. Run the Arca bridge bootstrap first.'
}

& gh auth status --hostname github.com 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

if (-not (Test-Path $Key)) {
    throw "Arca SSH key missing: $Key"
}

# Stop the stuck GitHub Actions worker/listener from holding SSH child processes.
Get-Process -Name 'Runner.Worker','Runner.Listener' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name 'ssh' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host 'Installing Posh-SSH / SSH.NET once...' -ForegroundColor Yellow
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
    Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}
Import-Module Posh-SSH -Force

$Secure = New-Object System.Security.SecureString
$Cred = New-Object System.Management.Automation.PSCredential('root', $Secure)
$LastId = -1

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
### Arca agent result #$Id — $Status

``````text
$Text
``````
"@

    $Tmp = Join-Path $env:TEMP 'arca-agent-result.md'
    [IO.File]::WriteAllText($Tmp, $Body, [Text.UTF8Encoding]::new($false))
    & gh issue comment $Issue --repo $Repo --body-file $Tmp 2>$null | Out-Null
}

function Get-AgentCommand {
    $RawB64 = (& gh api "repos/$Repo/contents/$CommandPath" --jq '.content' 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RawB64)) { return $null }
    $RawB64 = $RawB64 -replace '\s',''
    $Json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RawB64))
    return ($Json | ConvertFrom-Json)
}

function Invoke-ArcaCommand {
    param([string]$Command,[int]$Timeout)

    $Session = $null
    try {
        $Session = @(New-SSHSession -ComputerName '192.168.1.1' -Credential $Cred -KeyFile $Key -AcceptKey -Force -ConnectionTimeout 8 -ErrorAction Stop)[0]
        if ($null -eq $Session -or -not $Session.Connected) {
            throw 'SSH.NET did not establish a session.'
        }
        $Result = Invoke-SSHCommand -SSHSession $Session -Command $Command -TimeOut $Timeout -ErrorAction Stop
        $Out = @()
        if ($Result.Output) { $Out += $Result.Output }
        if ($Result.Error) { $Out += ($Result.Error | ForEach-Object { "STDERR: $_" }) }
        $Out += "REMOTE_EXIT=$($Result.ExitStatus)"
        return ($Out -join "`n")
    }
    finally {
        if ($null -ne $Session) {
            Remove-SSHSession -SSHSession $Session -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Write-Host 'Agent online. Keep this PowerShell window open.' -ForegroundColor Green
Write-Host 'You do not need to type router commands anymore.' -ForegroundColor Green
Post-AgentResult -Id 0 -Status 'ONLINE' -Text "Agent started on $env:COMPUTERNAME as $env:USERNAME. Key=$Key"

while ($true) {
    try {
        $Job = Get-AgentCommand
        if ($null -ne $Job) {
            $Id = [int]$Job.id
            if ($Id -ne $LastId) {
                $LastId = $Id
                if ([string]$Job.command -eq '__STOP__') {
                    Post-AgentResult -Id $Id -Status 'STOPPED' -Text 'Agent stop requested.'
                    break
                }

                $Timeout = 30
                if ($null -ne $Job.timeout) { $Timeout = [Math]::Max(5,[Math]::Min(180,[int]$Job.timeout)) }
                Write-Host "Executing command #$Id (timeout ${Timeout}s)..." -ForegroundColor Cyan

                try {
                    $Text = Invoke-ArcaCommand -Command ([string]$Job.command) -Timeout $Timeout
                    Post-AgentResult -Id $Id -Status 'DONE' -Text $Text
                    Write-Host "Command #$Id done." -ForegroundColor Green
                }
                catch {
                    $Msg = $_ | Out-String
                    Post-AgentResult -Id $Id -Status 'ERROR' -Text $Msg
                    Write-Host "Command #$Id error: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    catch {
        Write-Host "Agent poll warning: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
    Start-Sleep -Seconds 3
}

Write-Host 'Arca Live Agent stopped.' -ForegroundColor Yellow

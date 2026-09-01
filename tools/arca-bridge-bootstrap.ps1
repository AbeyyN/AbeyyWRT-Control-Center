$ErrorActionPreference = 'Stop'

Write-Host '=== ABEYYWRT ARCA BRIDGE BOOTSTRAP ===' -ForegroundColor Cyan

# Require elevated shell only for metric adjustment; continue without it if needed.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$eth = Get-NetAdapter -Physical | Where-Object {
    $_.InterfaceDescription -notmatch 'Wireless|Wi-Fi|Bluetooth'
} | Sort-Object @{Expression={ if ($_.Status -eq 'Up') {0} else {1} }} | Select-Object -First 1

if (-not $eth) { throw 'Ethernet adapter tak jumpa.' }
Write-Host ("Ethernet: {0} ({1})" -f $eth.Name,$eth.Status)

# Do NOT disable DHCP or replace the LAN IP. Arca DHCP is already working.
# Only make Ethernet unattractive as an Internet default route, while its connected
# 192.168.1.0/24 route remains usable for router management.
if ($isAdmin) {
    try {
        Set-NetIPInterface -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 500 -ErrorAction Stop
        Write-Host 'Ethernet metric set to 500; Internet can stay on Wi-Fi/USB tether.' -ForegroundColor Green
    } catch {
        Write-Warning "Metric change skipped: $($_.Exception.Message)"
    }
} else {
    Write-Warning 'PowerShell is not Administrator; metric unchanged. If GitHub cannot connect, use phone hotspot/USB tether as the preferred Internet adapter.'
}

Write-Host 'Checking Arca SSH...'
$arca = Test-NetConnection 192.168.1.1 -Port 22 -WarningAction SilentlyContinue
if (-not $arca.TcpTestSucceeded) {
    throw 'Arca 192.168.1.1:22 tak boleh dicapai. Pastikan kabel Ethernet laptop masuk LAN1/LAN2 Arca.'
}
Write-Host 'ARCA LAN OK' -ForegroundColor Green

Write-Host 'Checking laptop Internet to GitHub...'
$ghnet = Test-NetConnection github.com -Port 443 -WarningAction SilentlyContinue
if (-not $ghnet.TcpTestSucceeded) {
    throw 'Laptop belum ada Internet ke GitHub. Sambung phone hotspot/USB tether, kemudian run command bootstrap yang sama semula.'
}
Write-Host 'LAPTOP INTERNET OK' -ForegroundColor Green

# Ensure OpenSSH Client
$sshCmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshCmd) {
    if (-not $isAdmin) { throw 'OpenSSH Client tiada. Run PowerShell as Administrator dan run bootstrap semula.' }
    $cap = Get-WindowsCapability -Online | Where-Object Name -Like 'OpenSSH.Client*' | Select-Object -First 1
    if (-not $cap) { throw 'Windows OpenSSH capability tak dijumpai.' }
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}

$sshDir = Join-Path $env:USERPROFILE '.ssh'
$key = Join-Path $sshDir 'arca_bridge'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if (-not (Test-Path $key)) {
    & ssh-keygen.exe -q -t ed25519 -f $key -N '' -C 'arca-bridge'
    if ($LASTEXITCODE -ne 0) { throw 'Gagal generate SSH key.' }
}

# Install key only if passwordless SSH is not working yet.
& ssh.exe -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@192.168.1.1 'echo ARCA_KEY_OK' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'SEKALI SAHAJA: masukkan password root Arca bila diminta.' -ForegroundColor Yellow
    Get-Content "$key.pub" | & ssh.exe -o StrictHostKeyChecking=accept-new root@192.168.1.1 'umask 077; mkdir -p /etc/dropbear; touch /etc/dropbear/authorized_keys; cat >> /etc/dropbear/authorized_keys; sort -u /etc/dropbear/authorized_keys -o /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys'
    if ($LASTEXITCODE -ne 0) { throw 'Gagal install SSH key ke Arca.' }
}

& ssh.exe -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.1 'echo ARCA_SSH_READY'
if ($LASTEXITCODE -ne 0) { throw 'Passwordless SSH ke Arca belum ready.' }
Write-Host 'PASSWORDLESS ARCA SSH OK' -ForegroundColor Green

# Ensure GitHub CLI
if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'GitHub CLI tiada dan winget tak tersedia.' }
    & winget.exe install --id GitHub.cli -e --silent --accept-package-agreements --accept-source-agreements
    $env:PATH = "C:\Program Files\GitHub CLI;$env:PATH"
}

& gh.exe auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'GitHub login diperlukan sekali. Follow device/browser login yang keluar.' -ForegroundColor Yellow
    & gh.exe auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw 'GitHub login gagal.' }
}

$token = (& gh.exe api -X POST repos/AbeyyN/OpenWRT---AbeyyWRT/actions/runners/registration-token --jq '.token').Trim()
if (-not $token) { throw 'Tak dapat runner registration token.' }

$runnerDir = 'C:\arca-runner'
New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null

if (-not (Test-Path (Join-Path $runnerDir 'run.cmd'))) {
    Write-Host 'Downloading GitHub Actions runner...'
    $headers = @{ 'User-Agent' = 'AbeyyWRT-Arca-Bridge' }
    $release = Invoke-RestMethod -Headers $headers 'https://api.github.com/repos/actions/runner/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match '^actions-runner-win-x64-.*\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'Windows x64 runner package tak jumpa.' }
    $zip = Join-Path $env:TEMP 'actions-runner-win-x64.zip'
    Invoke-WebRequest -Headers $headers $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $runnerDir -Force
}

Push-Location $runnerDir
try {
    if (-not (Test-Path (Join-Path $runnerDir '.runner'))) {
        & .\config.cmd --unattended --url 'https://github.com/AbeyyN/OpenWRT---AbeyyWRT' --token $token --name 'ARCA-BRIDGE-WINDOWS' --labels 'arca-bridge' --work '_work' --replace
        if ($LASTEXITCODE -ne 0) { throw 'Runner registration gagal.' }
    }

    Get-Process Runner.Listener -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $log = Join-Path $runnerDir 'runner.log'
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c cd /d $runnerDir && run.cmd > `"$log`" 2>&1" -WindowStyle Hidden
    Start-Sleep 8
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' ARCA REMOTE BRIDGE READY' -ForegroundColor Green
Write-Host ' Runner: ARCA-BRIDGE-WINDOWS' -ForegroundColor Green
Write-Host ' Router: 192.168.1.1' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
if (Test-Path 'C:\arca-runner\runner.log') { Get-Content 'C:\arca-runner\runner.log' -Tail 20 }

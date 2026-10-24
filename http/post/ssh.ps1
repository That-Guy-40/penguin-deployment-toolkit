# ssh.ps1 - OpenSSH Server for a role with SSH=on, run by firstlogon.cmd (elevated) as:
#   powershell -NoProfile -ExecutionPolicy Bypass -File ssh.ps1 <msi> <authorized_keys> <sshd_config> <report.txt>
# Installs Win32-OpenSSH from the MSI (fetched from the server, pinned by
# bin/fetch-tools openssh) unless an sshd service exists already, writes the
# toolkit's sshd_config (key-only; a "powershell" subsystem when PowerShell 7 is
# installed, which is what PowerShell remoting over SSH needs), puts the role's
# keys in administrators_authorized_keys with the ACL sshd insists on, sets the
# default shell, opens the firewall and starts the service.
# Output (stdout, read back by firstlogon.cmd): quoted key=value tokens, one line:
#   "port=22" "shell=pwsh|powershell" "keys=N" "listening=yes|no" "failed=step(reason),..."
param([Parameter(Mandatory)][string]$Msi, [Parameter(Mandatory)][string]$Keys,
      [Parameter(Mandatory)][string]$Config, [Parameter(Mandatory)][string]$Report)
$ErrorActionPreference = 'Stop'
$failed = @()
$pd = Join-Path $env:ProgramData 'ssh'
$bin = Join-Path $env:ProgramFiles 'OpenSSH'
function Log($s) { Add-Content -LiteralPath $Report -Value $s -Encoding ASCII }
function Try-Step($name, [scriptblock]$b) {
    try { & $b } catch { $script:failed += "$name($($_.Exception.Message.Trim() -replace '[\s|&=,"]+', '_'))"; Log "FAILED $name : $($_.Exception.Message)" }
}
Set-Content -LiteralPath $Report -Value "ssh.ps1 $(Get-Date -Format s)" -Encoding ASCII

Try-Step 'install' {
    if (Get-Service sshd -ErrorAction SilentlyContinue) { Log 'sshd service already present; not installing'; return }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$Msi`" /qn /norestart /l*v `"$env:TEMP\openssh-msi.log`"" -Wait -PassThru
    Log "msiexec exit code $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "msiexec exit code $($p.ExitCode)" }
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'no sshd service after the MSI' }
}
# Configure with the service stopped: its first start would otherwise write a
# default sshd_config (passwords on) that we would then be racing.
Try-Step 'stop' { if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running') { Stop-Service sshd } }
New-Item -ItemType Directory -Path $pd -Force | Out-Null

$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$shell = if (Test-Path $pwsh) { 'pwsh' } else { 'powershell' }
Try-Step 'config' {
    $cfg = Get-Content -LiteralPath $Config -Raw
    # Microsoft's documented form for the remoting subsystem: the 8.3 path, no spaces.
    $sub = if ($shell -eq 'pwsh') { 'Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -nologo' }
           else { '# no PowerShell 7 on this machine: no powershell subsystem (remoting needs pwsh -sshs)' }
    $cfg = $cfg -replace '@PWSH_SUBSYSTEM@', $sub
    Set-Content -LiteralPath (Join-Path $pd 'sshd_config') -Value $cfg -Encoding ASCII
    $shellExe = if ($shell -eq 'pwsh') { $pwsh } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shellExe -Type String
    Log "default shell $shellExe"
}
$nkeys = 0
Try-Step 'keys' {
    $lines = Get-Content -LiteralPath $Keys | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' }
    $script:nkeys = @($lines).Count
    if ($script:nkeys -eq 0) { throw 'no public key in the keys file' }
    $ak = Join-Path $pd 'administrators_authorized_keys'
    Set-Content -LiteralPath $ak -Value $lines -Encoding ASCII
    # sshd refuses the file unless only Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18) can touch it.
    $out = & icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls: $out" }
    Log "$script:nkeys key(s) in $ak"
}
Try-Step 'hostkeys' {
    # New host keys if there are none (also after prepare-capture removed them on a reference machine).
    if (-not (Test-Path (Join-Path $pd 'ssh_host_ed25519_key'))) { & (Join-Path $bin 'ssh-keygen.exe') -A 2>&1 | ForEach-Object { Log "ssh-keygen: $_" } }
    Get-ChildItem -LiteralPath $pd -Filter 'ssh_host_*_key.pub' | ForEach-Object { Log ("hostkey " + (& (Join-Path $bin 'ssh-keygen.exe') -lf $_.FullName)) }
}
Try-Step 'firewall' {
    if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
    } else {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
}
Try-Step 'service' {
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
}
$listening = 'no'
foreach ($i in 1..10) {
    if ((Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) { $listening = 'yes'; break }
    Start-Sleep -Seconds 1
}
Log "sshd $((Get-Service sshd -ErrorAction SilentlyContinue).Status), listening=$listening"
if (Test-Path "$env:TEMP\openssh-msi.log") { Log '=== msi log (tail)'; Get-Content "$env:TEMP\openssh-msi.log" -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ } }
"`"port=22`" `"shell=$shell`" `"keys=$nkeys`" `"listening=$listening`"" + $(if ($failed) { " `"failed=$($failed -join ',')`"" } else { '' })

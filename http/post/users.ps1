# users.ps1 - local accounts from the role's users list, run by firstlogon.cmd
# (elevated) as:  powershell -NoProfile -ExecutionPolicy Bypass -File users.ps1 <users.txt> <out.txt>
#
# users.txt, one account per line, # comments:
#   name|group|random            create (or keep) the account; set a new random password
#   name|group|plain:<password>  create (or keep) the account; set exactly this password
#   name|group|policy|keys=<file>  ... and install the SSH public keys in <file> (a file
#                                in the role directory, next to users.txt) for that account
#                                as C:\ProgramData\ssh\users\<name>\authorized_keys, owned
#                                by Administrators, readable by the account: the path the
#                                toolkit's sshd_config lists for every non-administrator
#                                (%USERPROFILE%\.ssh does not exist before a first logon)
# group is Administrators or Users. An account that already exists (the unattend's
# "deploy", for one) is not created again: only its password and group are set.
#
# Every password that was set is written to <out.txt> as "name<TAB>password", one
# line each. firstlogon.cmd uploads that file to the server's write-only uploads
# endpoint (readable only on the server, by its owner) and deletes it from the
# disk at the end of first logon. Nothing else keeps the generated passwords.
#
# Output (stdout, read back by firstlogon.cmd): one line
#   created=a,b set=c failed=d(reason) keys=a
param([Parameter(Mandatory)][string]$List, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$created = @(); $set = @(); $failed = @(); $keyed = @()
$lines = @()

function Install-UserKeys([string]$name, [string]$file) {
    $pub = @(Get-Content -LiteralPath $file | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' })
    if ($pub.Count -eq 0) { throw "no public key in $(Split-Path -Leaf $file)" }
    $d = Join-Path $env:ProgramData "ssh\users\$name"
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $ak = Join-Path $d 'authorized_keys'
    Set-Content -LiteralPath $ak -Value $pub -Encoding ASCII
    # sshd (StrictModes) wants the file owned by the account or an administrator and
    # writable by nobody else: Administrators and SYSTEM full, the account read.
    foreach ($p in @(@($d, 'RX'), @($ak, 'R'))) {
        $out = & icacls.exe $p[0] /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /grant "$($name):$($p[1])" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "icacls: $out" }
    }
    return $pub.Count
}

function New-RandomPassword {
    # 24 random bytes from the OS generator, base64: 32 characters of upper,
    # lower and digits (and + /), no padding. Meets the default complexity policy.
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    [Convert]::ToBase64String($b)
}

foreach ($raw in Get-Content -LiteralPath $List) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $f = $line.Split('|')
    if ($f.Count -lt 3 -or $f.Count -gt 4) { $failed += "$($f[0].Trim())(not name|group|policy[|keys=file])"; continue }
    $name, $group, $policy = $f[0].Trim(), $f[1].Trim(), $f[2].Trim()
    $keysFile = $null
    if ($f.Count -eq 4) {
        if ($f[3].Trim() -notmatch '^keys=([A-Za-z0-9._-]+)$') { $failed += "$name(fourth field must be keys=<file>)"; continue }
        $keysFile = Join-Path (Split-Path -Parent $List) $Matches[1]
        if (-not (Test-Path -LiteralPath $keysFile)) { $failed += "$name(keys file $($Matches[1]) missing)"; continue }
    }
    if ($name -notmatch '^[A-Za-z0-9._-]{1,20}$') { $failed += "$name(bad name)"; continue }
    if ($group -notin @('Administrators', 'Users')) { $failed += "$name(group must be Administrators or Users)"; continue }
    if ($policy -eq 'random') { $pw = New-RandomPassword }
    elseif ($policy.StartsWith('plain:')) { $pw = $policy.Substring(6) }
    else { $failed += "$name(policy must be random or plain:...)"; continue }
    $secure = ConvertTo-SecureString $pw -AsPlainText -Force
    try {
        $existing = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
        if ($existing) {
            Set-LocalUser -Name $name -Password $secure -PasswordNeverExpires $true
            $set += $name
        } else {
            New-LocalUser -Name $name -Password $secure -PasswordNeverExpires -AccountNeverExpires | Out-Null
            $created += $name
        }
        if (-not (Get-LocalGroupMember -Group $group -Member $name -ErrorAction SilentlyContinue)) {
            Add-LocalGroupMember -Group $group -Member $name
        }
        $lines += "$name`t$pw"
        if ($keysFile) { Install-UserKeys $name $keysFile | Out-Null; $keyed += $name }
    } catch {
        $failed += "$name($($_.Exception.Message.Trim() -replace '[\s|&=,]+', '_'))"
    }
}
# The passwords file: only SYSTEM and this account may read it, for the few
# seconds it exists (C:\pdt is readable by every local user otherwise). The
# ACL is set before anything is written.
New-Item -ItemType File -Path $Out -Force | Out-Null
$acl = Get-Acl -LiteralPath $Out
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
foreach ($id in @('NT AUTHORITY\SYSTEM', $me)) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
}
Set-Acl -LiteralPath $Out -AclObject $acl
Set-Content -LiteralPath $Out -Value $lines -Encoding ASCII
"created=$($created -join ',') set=$($set -join ',') failed=$(($failed -join ',') -replace '\s+', '_') keys=$($keyed -join ',')"

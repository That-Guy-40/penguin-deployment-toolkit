# users.ps1 - local accounts from the role's users list, run by firstlogon.cmd
# (elevated) as:  powershell -NoProfile -ExecutionPolicy Bypass -File users.ps1 <users.txt> <out.txt>
#
# users.txt, one account per line, # comments:
#   name|group|random            create (or keep) the account; set a new random password
#   name|group|plain:<password>  create (or keep) the account; set exactly this password
# group is Administrators or Users. An account that already exists (the unattend's
# "deploy", for one) is not created again: only its password and group are set.
#
# Every password that was set is written to <out.txt> as "name<TAB>password", one
# line each. firstlogon.cmd uploads that file to the server's write-only uploads
# endpoint (readable only on the server, by its owner) and deletes it from the
# disk at the end of first logon. Nothing else keeps the generated passwords.
#
# Output (stdout, read back by firstlogon.cmd): one line
#   created=a,b set=c failed=d(reason)
param([Parameter(Mandatory)][string]$List, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$created = @(); $set = @(); $failed = @()
$lines = @()

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
    if ($f.Count -ne 3) { $failed += "$($f[0].Trim())(not name|group|policy)"; continue }
    $name, $group, $policy = $f[0].Trim(), $f[1].Trim(), $f[2].Trim()
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
"created=$($created -join ',') set=$($set -join ',') failed=$(($failed -join ',') -replace '\s+', '_')"

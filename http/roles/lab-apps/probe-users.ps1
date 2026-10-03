# probe-users.ps1 <users-out.txt> - the lab role's check of users.ps1's work.
# Logs on as each listed account (a process with that credential, profile
# loaded), which creates the profile from C:\Users\Default. Prints KEY=value
# lines for post.cmd.
param([string]$Out)
$pw = @{}
foreach ($l in Get-Content $Out) { $n, $p = $l.Split("`t"); $pw[$n] = $p }
function Test-Logon($name, $password) {
    try {
        $cred = New-Object PSCredential($name, (ConvertTo-SecureString $password -AsPlainText -Force))
        $p = Start-Process cmd.exe -ArgumentList '/c exit 0' -Credential $cred -LoadUserProfile -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
        return 'yes'
    } catch { return 'no' }
}
if ($pw.ContainsKey('alice')) {
    "ALICE_LOGON=" + (Test-Logon 'alice' $pw['alice'])
    "ALICE_SKEL=" + $(if (Test-Path 'C:\Users\alice\Desktop\hello.txt') { 'yes' } else { 'no' })
}
# deploy's generated password works: its blank lab password is gone.
if ($pw.ContainsKey('deploy')) { "DEPLOY_LOGON=" + (Test-Logon 'deploy' $pw['deploy']) }

# 2026-10-02: accounts and a skel for new profiles (role keys USERS, SKEL, FILES)

The idea, from Linux: `adduser` plus `/etc/skel`. On Windows the skel is
`C:\Users\Default`, copied into every profile at that user's first logon.

Built: `USERS=users.txt` (`name|group|random` or `name|group|plain:<pw>`,
applied by `post/users.ps1`: create the account or, if it exists such as the
unattend's `deploy`, set its password; generated passwords written to
`C:\pdt\users-out.txt` with an owner+SYSTEM-only ACL, uploaded to the
server's write-only endpoint as `users.txt`, deleted at the end of first
logon and again by `prepare-capture.cmd`), `SKEL=skel.txt` (a manifest of
files under `skel/`, copied into `C:\Users\Default`), `FILES=` (companions
of the post script). Checked by WinPE's preflight and by `bin/lint`
(manifest versus directory both ways, every users line, 32 self-test defects).
`bin/serve` now stores uploads owner-only (`dav_access user:rw`).

All in lab VMs on this host; `beacons.txt` has every event.

## 1. First attempt: two defects, found by the beacons **[verified fail]**

VM `ru` (role `lab-apps` with `deploy|Administrators|random`,
`alice|Users|random`, a two-file skel): `skel ok files=2`, then
`users fail created= set=deploy failed=alice(A` and `users-upload fail …
left in C:\pdt\users-out.txt`. A diagnostic typed into the guest
(`ru1-first-attempt-diag.txt`):

- `New-LocalUser : A positional parameter cannot be found that accepts
  argument 'True'`: `-PasswordNeverExpires` is a switch on `New-LocalUser`
  and a boolean on `Set-LocalUser`. `deploy` (the Set path) worked, `alice`
  (the New path) did not.
- `icacls C:\pdt\users-out.txt: Access is denied` and `curl: Can't open`:
  the `icacls /inheritance:r /grant:r …` call had stripped the ACL and granted
  nothing, so nobody could read the file. The upload failing is why the
  file is *kept* in that case and the beacon says where: the alternative
  is passwords that exist nowhere.
- The failure text was cut at its first space by the beacon's tokenizer.

All three fixed (`users.ps1` sets the ACL through `Set-Acl` with explicit
rules before writing; failure text has no spaces).

## 2. Second attempt **[verified]**

VM `ru` again:

```
21:11:19  skel ok          files=2
21:11:20  users ok         created=alice set=deploy failed=
21:11:20  users-upload ok  generated passwords are in the uploads as users.txt
21:11:46  role-post ok     sevenzip=yes alice_logon=yes alice_skel=yes deploy_logon=yes
21:11:46  deployed ok      role=lab-apps
```

The role's `post.cmd` + `probe-users.ps1` is the check: it reads the
passwords file (still present at that point), starts a process as `alice`
and as `deploy` with those passwords (`Start-Process -Credential
-LoadUserProfile`), which creates alice's profile, and tests
`C:\Users\alice\Desktop\hello.txt`. On the server, `uploads/<id>/<run>/users.txt`
has two lines (`deploy`, `alice`), 32-character passwords.

In the guest afterwards (`ru-guest-diag.txt`, non-elevated; `ru-guest-diag-elevated.txt`,
through a UAC prompt answered by `vm-type`): `C:\pdt` has no
`users-out.txt`; `C:\Users\Default\Desktop\hello.txt` and
`Documents\pdt-readme.txt` are there; `C:\Users\alice\Desktop` and
`Documents` hold the same two files; `net user alice`: password never expires.
(The non-elevated listing of alice's profile said "File Not Found": the
filtered token cannot see into another user's profile. The elevated one is
the evidence.)

## 3. Negative control **[verified]**

VM `rv`, role `lab-bad2`: `bob|Users|random`, `bad name|Users|random`,
`carol|Users|nothing`. `bin/lint` refuses the file (two problems named).
Served anyway: `users fail created=bob set= failed=bad_name(bad_name),carol(policy_must_be_random_or_plain:...)`,
`users-upload ok` (bob's password), `deployed ok`. The first run of this VM
had its `failed=` cut at "bad" (the space in the name), fixed in users.ps1.

A run of this VM was also lost to a `bin/serve` restart while WinPE was
fetching its toolkit: a reminder that the server is the control plane, and
restarting it during a deploy is not free.

## 4. Not done

Domain join. Removing `deploy` (it has to exist until first logon ends; a
role re-passwords it instead). Templating the Default profile's registry
hive (`NTUSER.DAT`): `SKEL` copies files only.

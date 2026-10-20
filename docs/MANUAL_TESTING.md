# Manual testing: the whole toolkit by hand, as of 2026-10-12

A procedure, not a tour: each step says what to type, what must happen,
and the control that proves the check can fail. Everything runs as an
unprivileged user on the host; the lab VMs need KVM. Budget: about an
hour, most of it waiting for installs (2.5 min each, 3.5 with a role).
Tick the boxes as you go; a box you cannot tick is a finding.

Prerequisites: `config.sh` from `config.sh.example` (ISO path, a free port),
`bin/fetch-tools`, `bin/stage-winpe`, `bin/stage-image`, `bin/build-ipxe`,
`bin/serve`. Then `bin/lint` must end in `0 FAIL`; if it does not, stop here.

## 0. The checker itself

- [ ] `bin/lint --selftest` says `35/35 injected defects were reported as FAIL`.
- [ ] Control: `echo 'MODE=wipe' > http/machines/00000000-0000-0000-0000-000000000000.cfg; bin/lint; rm http/machines/00000000-*.cfg`
      → one `FAIL … MODE=wipe`, exit 1.

## 1. An unlisted machine is never touched

- [ ] `bin/vm-create t0 --mode none && bin/vm-boot t0`; within a minute
      `bin/status` shows `t0` with `shell ok`, product `lab-vm`.
- [ ] `bin/vm-shot t0` shows the WinPE prompt with "MODE=shell: nothing will
      be changed". `bin/shell t0 'dir C:\'` → "The system cannot find the
      path specified" (no partition was made).
- [ ] `bin/vm-stop t0 --force; bin/teardown --purge-vm t0 --yes`.

## 2. A plain deploy

- [ ] `bin/vm-create t1 && bin/vm-boot t1 && bin/await t1 deployed 900`
      exits 0 in about 2.5 minutes. `bin/status t1`: every step `ok`, then
      `specialize`, `firstlogon` (build, `secureboot=False`), `winre ok`
      (status Enabled, location partition4, windows_partition=3),
      `boot-tasks ok`, `deployed ok role=`.
- [ ] `bin/logs t1` lists `ts.log`, `dism.log`, `reagentc.txt`, the Panther
      logs. `bin/vm-shot t1` shows a desktop.
- [ ] Control (preflight): `sed -i 's/^IMAGE=.*/IMAGE=nope.wim/' http/machines/<t1 uuid>.cfg`,
      `bin/vm-boot t1 --pxe`: `15-preflight fail … missing: images/nope.wim`,
      `bin/await t1 deployed 60` exits 1, the disk is untouched (the old
      Windows still boots with `bin/vm-boot t1`). Restore the cfg.

## 3. Watching

- [ ] During a deploy, `bin/logs t1 --tail 5 ts.log` follows the log (pushed
      every 20 s) and `bin/status --watch` shows the step as `busy`.
- [ ] `bin/shell t1 'dir W:\'` during `30-apply` lists the half-applied
      volume; `bin/screen t1` shows the WinPE console (requires
      `bin/build-tools` once, mingw-w64).
- [ ] Control: `bin/shell t1 'nosuchprogram'` → "not recognized", exit 1.

## 4. A role: apps, accounts, skel, policy, removal

- [ ] `bin/vm-create t2 --role lab-apps && bin/vm-boot t2 && bin/await t2 deployed 900`.
      `bin/status t2`, after `winre`: `skel ok files=2`, `skelreg ok`,
      `users ok created=admin,alice set=deploy failed=`, `users-upload ok`,
      `winget ok version=…`, `apps ok installed=7zip.7zip,Notepad++.Notepad++ failed=`,
      `faststartup ok state=off`, `boot-tasks ok`, `role-post ok sevenzip=yes
      alice_logon=yes alice_skel=yes deploy_logon=yes alice_skelreg=lab-apps`,
      `deployed ok role=lab-apps`, `deploy-remove ok account=deleted`, then
      after the restart `boot ok trigger=onstart` and `deploy-removed ok`.
- [ ] `bin/logs t2 --cat users.txt`: two lines, `admin` and `alice`, 32-char
      passwords. `bin/vm-shot t2` (press Enter first with `bin/vm-type t2
      --key ret`): the sign-in picker shows `admin` and `alice` only.
- [ ] RDP (the role has `RDP=on`; boot t2 with `--fwd 3390:3389`): `rdp ok
      listening=yes` in the timeline; `xfreerdp /v:127.0.0.1:3390 /u:admin
      /p:<admin's line in bin/logs t2 --cat users.txt> /cert:ignore /auth-only`
      exits 0; with a wrong password it does not. Control: a VM without the
      key answers nothing on its forwarded 3389.
- [ ] Power cycle: `bin/vm-stop t2` returns in seconds (fast startup is off
      for this role); `bin/vm-boot t2` → `boot ok trigger=onstart` within a
      minute.
- [ ] Control (role): `mkdir http/roles/bad; printf 'APPS=apps.txt\n' > http/roles/bad/role.cfg; printf 'No.Such.Package.Zzz\n' > http/roles/bad/apps.txt`;
      a VM with `--role bad` reports `apps fail … failed=No.Such.Package.Zzz(…)`
      and still `deployed ok`. `bin/lint` passes this role (the id is
      well-formed; only winget knows it does not exist). Remove `roles/bad`.
- [ ] Control (lint): `printf 'DEPLOY=remove\n' >> http/roles/bad2/role.cfg`
      with no `USERS` → `bin/lint`: `FAIL … USERS must create another
      Administrators account first`.

## 5. A reference image and a deploy from it

- [ ] `bin/vm-create t3 --reference --role lab-apps && bin/vm-boot t3 && bin/await t3 deployed 900`;
      then QEMU exits by itself within a minute (sysprep's shutdown).
- [ ] `bin/capture-image t3 lab-apps` (about 90 s): the printed sidecar has
      `provenance.role = lab-apps` and `provenance.apps_sha256` equal to
      `sha256sum http/roles/lab-apps/apps.txt`.
- [ ] `bin/vm-create t4 --image lab-apps && bin/vm-boot t4 && bin/await t4 deployed 900`:
      `firstlogon … image=reference … role lab-apps apps <hash>`, no
      `winget`/`apps` events (no role on t4), `deployed ok role=`.

## 6. The collector (Linux in RAM) and the hand-over

- [ ] `bin/build-collector` (needs mmdebstrap; a few minutes the first time)
      → `http/collector/{vmlinuz,initrd.img,collector.json}`.
- [ ] `bin/vm-create t5 --mode none && bin/netboot t5 collector && bin/vm-boot t5 && bin/await t5 collect 300`:
      `collect ok product=lab-vm serial=t5 amt=absent firmware=none pxe_entry=00NN ssh=up`
      within about 10 s of the iPXE request; `vms/t5/serial.log` ends in a
      login prompt; `bin/logs t5 --cat inventory.json` is valid JSON with the
      NIC's MAC.
- [ ] `bin/shell t5 'uname -r; ss -ltn | grep :22'`: a Debian kernel, sshd
      listening. For a real login, boot it with `bin/vm-boot t5 --fwd 2222:22`
      and `ssh -p 2222 -i ~/.ssh/id_ed25519 root@127.0.0.1 hostname` →
      `pdt-collector`. Control: `ssh -p 2222 -o PubkeyAuthentication=no
      root@127.0.0.1 true` → `Permission denied (publickey)`.
- [ ] `bin/enroll t5 --role lab-apps` writes `machines/<uuid>.cfg`; a second
      `bin/enroll t5` refuses without `--force`.
- [ ] `bin/netboot t5 winpe && bin/shell t5 'pdt-pxe-next --reboot'` prints
      `BootNext=00NN: … UEFI PXEv4 …`; the VM reboots into WinPE and
      `bin/await t5 deployed 900` exits 0.
- [ ] BootNext, the real test (the disk is bootable now): `bin/netboot t5 collector; bin/vm-stop t5; bin/vm-boot t5 --pxe; bin/await t5 collect 300; bin/shell t5 'pdt-pxe-next'; bin/vm-stop t5; bin/vm-boot t5`
      (disk first) → `collect ok` again: the firmware honoured BootNext over
      its boot order. Control: `bin/vm-stop t5; bin/vm-boot t5` once more →
      Windows boots (`boot ok` from the installed system), no `collect`.

## 7. The bridged lab (what real hardware does)

- [ ] `docs/LAB_FROM_SCRATCH.md` or, without root, README "The bridged lab,
      without root": a deploy over dnsmasq DHCP + TFTP. Control: stop
      `pxe-lan`; the same VM never leaves "Start PXE over IPv4".

## 8. Clean up

- [ ] `bin/teardown --purge-vm tN --yes` for each VM; `rm -rf http/cmd http/boot/*.ipxe`
      if you made overrides; `bin/lint` still `0 FAIL`.

## Not covered by this procedure (no hardware)

Physical PXE next to a real DHCP server, the Dell driver pack on the
Latitude, Secure Boot certificate enrolment in real firmware, AMT, firmware
attributes through `dell-wmi-sysman` (the VM has none: `firmware=none` is
the honest result there), and a real SSH session into the collector.

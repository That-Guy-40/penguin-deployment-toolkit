# The layers, one by one: what each does, and how to add or change things in it

`docs/HOW_IT_WORKS.md` tells the story once; `docs/CONTROL_POINTS.md` is the
table of "which file, when". This page is the third angle: every layer on
its own, with the recipes for extending it. Each recipe ends with how
`bin/lint` or a lab VM proves the change. Nothing here needs root.

```
 firmware ──► iPXE ──► WinPE + task sequence ──► image/packs ──► unattend ──► first logon (role) ──► installed OS
                │                                                                                      ▲
                └──► the collector (Linux in RAM) ── inventory, shell, ssh ── pdt-pxe-next ────────────┘
 the server: nginx (static files, beacons, uploads) + bin/ (status, await, logs, shell, screen, lint, enroll, netboot)
```

## 1. Firmware and DHCP → `ipxe.efi`

**What it does.** The machine's firmware PXE client gets `ipxe.efi` from
`bin/pxe-lan` (dnsmasq: proxy-DHCP beside your router, or full DHCP on a lab
bridge) over TFTP. `ipxe.efi` is built by `bin/build-ipxe` from a pinned iPXE
commit with one embedded line: chain `http://HOST:PORT/boot.ipxe?uuid=…&mac=…&product=…`.

**Tweak.** The server address lives in `config.sh` (`HTTP_HOST`, `HTTP_PORT`);
change it, run `bin/build-ipxe`, and every machine boots to the new address
next time. Secure Boot: set `SB_KEY`/`SB_CERT`, rebuild, enrol the certificate
in the firmware. The embedded script is in `bin/build-ipxe` itself; add a
variable there if you want another identity field reported.

**Prove it.** `bin/status` after a boot shows `ipxe ok product=… mac=… nic=…
bootsrv=…` with the new values; `bin/lint` checks `pxe/ipxe.efi` exists and
is the pinned build.

## 2. iPXE → what to boot: `http/boot.ipxe`

**What it does.** One static script with relative URLs. First `boot/<uuid>.ipxe`,
then `boot/default.ipxe` (both optional one-liners written by `bin/netboot`:
`set pdt_boot collector`), then either the collector (`collector/vmlinuz` +
`initrd.img`, with `pdt.server=` and `pdt.id=` on the command line) or
Windows PE: `wimboot` with the pristine `boot.wim` and the files it injects
into `X:\Windows\System32` (`winpeshl.ini`, `deploy.cmd`, `id.cmd`,
`curl.exe`), plus the optional WinPE driver snippet for this NIC or model.

**Add a file to WinPE.** One `initrd --name <name> <path>` line in
`boot.ipxe`; the file appears as `X:\Windows\System32\<name>`. That is how
`curl.exe` got there. Use it for a tool WinPE lacks (a static binary).

**Add WinPE-side drivers for a NIC or model.** `http/winpe-drivers/<pci-id>.ipxe`
or `model-<product-slug>.ipxe`: `initrd` lines for every file of the driver
plus `pdt-drvload.txt` naming the `.inf`s; `deploy.cmd` runs `drvload` on
them before the network comes up. `bin/fetch-tools virtio` is the generated
example; `http/winpe-drivers/README.md` has the naming rule.

**Add a third thing to boot.** A new label in `boot.ipxe` (`:mything`), a
new `iseq ${pdt_boot} mything && goto mything ||` line, and `bin/netboot`'s
`choices`. Keep every `kernel`/`initrd` line in `boot.ipxe` itself so `lint`
can check the files exist (it reads the script, follows `winpe-drivers/`
snippets, and knows a line ending in `||` is optional).

**Prove it.** `bin/lint -v | grep boot.ipxe` lists every reference and its
state; a VM boot shows `wim ok` (the `boot.wim` request) or the collector's
`collect ok`.

## 3. WinPE and the task sequence: `http/ts/`

**What it does.** `winpeshl.ini` runs `deploy.cmd`: wait for the network,
fetch the toolkit (`env.cmd`, `step.cmd`, `beacon.cmd`, `push.cmd`,
`pushloop.cmd`, `shell-loop.cmd`, `slug.js`), identify the machine, layer
`models/<slug>.cfg` under `machines/<uuid>.cfg`, start the remote shell, and
run `ts/<MODE>.seq`: one step file per line, each run in a child `cmd` with
`start`/`ok`/`fail` beacons and logs pushed every 20 s. No cfg: `MODE=shell`,
a prompt, nothing written.

**Add a step.** `http/ts/steps/NN-name.cmd` (CRLF; `@echo off`, `call
X:\pdt\env.cmd`, do the work, `exit /b <rc>`), and its name in the `.seq`
files that should run it. Only use programs WinPE has or that `boot.ipxe`
injects: `lint` reads the program list out of `boot.wim` and fails a step
that pipes into something missing (a missing program in a pipe silently ends
the whole batch stack: the reason steps run in child processes). Output
goes to `%LOG%`; one `beacon.cmd <step> fail "msg=…"` on failure is
`step.cmd`'s job, not the step's.

**Add a cfg key.** `env.cmd` (the default and the two `for %%k` lists:
model-allowed keys and machine-only keys), `bin/lint` (`MODEL_KEYS` /
`MACHINE_ONLY_KEYS`, plus a `check_asset` entry if it names a file),
`http/machines/README.md`. Whether a key may come from a model file is the
design decision: nothing that wipes a disk may.

**Add a mode.** `http/ts/<mode>.seq` listing existing or new steps; `lint`
checks that every listed step exists and every step is in some sequence.
`capture.seq` is the example: one step, `70-capture`.

**Prove it.** `bin/lint`; a VM with `STOP_BEFORE=NN` stops at the prompt
with the environment loaded, the step can be run by hand (`X:\pdt\steps\NN-name.cmd`
or through `bin/shell`), and `deploy NN` resumes.

## 4. Images and packs: `http/images/`, `drivers/`, `updates/`

**What it does.** `30-apply` lays down `images/<IMAGE>.wim`; `35-updates`
installs the packages in an update pack; `40-drivers` adds a driver pack;
`45-winre` puts `images/<IMAGE>.winre.wim` on the recovery partition. Every
image and pack has a `.json` sidecar (size, SHA-256, what is inside) and
`lint` refuses one whose sidecar is missing or disagrees.

**Add an image.** `bin/stage-image` (from the ISO), or a captured one:
deploy a reference machine (`REFERENCE=yes`, with a role), let it sysprep
itself, `bin/capture-image <vm> <name>`; the sidecar's `provenance` records
the role and its apps-list hash. Point a machine at it with `IMAGE=<name>.wim`.

**Add a driver pack.** `bin/fetch-drivers <vendor-url> <name>` (Dell/Lenovo/HP
CAB or zip; pinned by hash on the second run) or `bin/pack-drivers <dir> <name>`,
then `DRIVERS=<name>` in `models/<slug>.cfg` so every machine of that model
gets it. **Add an update pack:** `bin/pack-updates <dir> <name> --target <file>
--expect <build>`; `UPDATES=<name>`.

**Prove it.** `lint` (sidecars); a deploy's `firstlogon` beacon carries the
build the installed system reports (`build=26100.9550` after a cumulative
update) and `40-drivers ok`.

## 5. The answer file and `C:\pdt`: `60-unattend`, `http/unattend/`

**What it does.** Writes `C:\Windows\Panther\unattend.xml` (the cfg's, or
the role's own) and recreates `C:\pdt\` with everything first logon needs:
identity, beacon, `firstlogon.cmd`, `boot-probe.cmd`, the role's files, the
machine's `POST` script, `prepare-capture.cmd` on a reference machine.

**Tweak the unattend.** Copy `http/unattend/default.xml`, change what you
need (locale, computer name pattern, OOBE), name it in a cfg (`UNATTEND=`)
or a role (`UNATTEND=` in `role.cfg`). Keep `FirstLogonCommands` calling
`C:\pdt\firstlogon.cmd` or nothing after Setup reports back. `lint` parses
the XML.

**Put another file on the installed system.** A `%CURL% -f -o W:\pdt\<file>
"%SRV%/post/<file>"` line in `60-unattend.cmd`, and the file under
`http/post/`; `lint` checks every `%SRV%/…` reference a step makes.

## 6. First logon and roles: `http/post/`, `http/roles/`

**What it does.** `firstlogon.cmd` (once, elevated, as `deploy`): WinRE check,
uploads, then the role from `C:\pdt\role\role.cfg`: skel files and registry
→ accounts (passwords generated, uploaded, deleted) → winget bootstrap and
apps → fast-startup policy → boot probe registered → role `post.cmd` →
machine `post.cmd` → `deployed` → (reference: sysprep) → (`DEPLOY=remove`:
delete the toolkit's account, restart).

**Add a role.** A directory `http/roles/<name>/` with `role.cfg`; the keys
and their files are in `http/roles/README.md`. `lab-apps/` is a complete
example including a `post.cmd` that probes its own work. `ROLE=<name>` in a
machine or model cfg, or `bin/enroll <m> --role <name>`.

**Add a role key.** Four places, all small: `firstlogon.cmd` (read it from
`role.cfg`, act), `15-preflight.cmd` (HEAD the file it names, so a typo fails
before the disk is touched), `60-unattend.cmd` (download the file into
`C:\pdt\role\`), `bin/lint` (`ROLE_KEYS`, the file/format check, and a
self-test defect that proves the check fires). `SKELREG` and `DEPLOY` were
added exactly this way; read their four hunks as the template.

**Add a beacon.** `call "%~dp0beacon.cmd" <step> ok|fail "key=value" …` from
any script on the machine; it appears in `bin/status` at once. To show a
new key in the timeline, add it to the key list in `bin/status`. Values must
not contain spaces (the beacon is a URL; `users.ps1` replaces them with `_`).

**Prove it.** A role VM to `deployed` with the new beacon in `bin/status <vm>`;
a negative control (the key pointing at a missing file → `15-preflight fail`;
a bad value → `lint FAIL`).

## 7. The installed OS, after first logon

**What it does.** Nothing of the toolkit's runs any more except the boot
probe (two scheduled tasks → `boot ok trigger=…` after every boot) and, with
`DEPLOY=remove`, the one-shot profile removal. No agent, by design.

**Add something that runs every boot.** A role `post.cmd` that registers its
own scheduled task, as `boot-probe.cmd` does (`schtasks /create /sc onstart
/ru SYSTEM …`), with the script left under `C:\pdt\` by the role's `FILES=`.
Remote access to the installed OS is Windows' own RDP, which a role switches
on with `RDP=on` (NLA, the firewall group, the role's accounts allowed).

## 8. The collector: `tools-src/collector/`, `bin/build-collector`

**What it does.** A Debian that boots from RAM over iPXE, runs `pdt-collect`
(inventory → `inventory.json`/`.txt` uploaded, `collect ok` beacon), then the
same command loop WinPE has (`bin/shell`), with sshd (your key) and
`pdt-pxe-next` to send the machine on to PXE/WinPE. `docs/COLLECTOR.md`.

**Add a tool.** Its Debian package name in `PACKAGES` in `bin/build-collector`;
rebuild (seconds once the cache is warm). A tool that is not packaged:
build it statically on the host (as `mei-amt-check` is) and `upload` it in
the mmdebstrap hooks. **Add something it collects:** `usr/local/bin/pdt-collect`
(a line in the JSON block and, if useful, a `key=value` on the `collect`
beacon); `bin/enroll` reads the JSON. **Change what it does at boot:** the
`pdt-collect.service` unit; `customize-inside.sh` for anything that must
happen inside the chroot at build time (hooks are inline strings: this
host's AppArmor profile for mmdebstrap allows no hook *files*).

**Prove it.** `bin/vm-create x --mode none; bin/netboot x collector; bin/vm-boot x;
bin/await x collect 300` and `bin/shell x '<the new tool>'`; `vms/x/serial.log`
is the console if it does not come up.

## 9. The server: `bin/serve` and the tools

**What it does.** nginx, rootless, serving `http/` as it is, plus three
dynamic things: `GET /beacon` → `run/beacons.log`, `GET /ts/id.cmd` (the
identity hand-off), `PUT /uploads/<id>/<run>/…` (write-only, owner-only
files). Everything in `bin/` that reads (`status`, `await`, `logs`, `shell`,
`screen`, `enroll`, `netboot`) works from those two logs and that directory.

**Add a tool that reads the state.** Python with `_pdt.py`: `all_events()`
(beacons plus the synthetic `ipxe`/`wim` events from the access log),
`resolve_id()` (VM name, UUID or prefix), `paths()`. `bin/await` is the
smallest example. **Add a server-side endpoint:** a `location` in `bin/serve`'s
nginx template, and a row in its self-test (`serve` tests its own endpoints
on every start; a new one without a test is the kind of thing that passes
silently).

**Add a lint check.** A row in `lint_tree` (`R.ok`/`R.fail`/`R.unknown` with
a one-line reason) and a defect in `selftest()`'s list that must make it
fire; `bin/lint --selftest` refuses to pass if any injected defect goes
unreported. That rule is the one that keeps the checker honest.

## 10. The lab: `bin/vm-*`, `bin/lab-netns`, `bin/pxe-lan`

**What it does.** QEMU VMs with a fixed SMBIOS UUID and MAC, OVMF, an iPXE
option ROM or firmware PXE (`--no-rom`), user-mode networking by default or
a bridge inside a rootless network namespace (`bin/lab-netns`) with dnsmasq
doing DHCP and TFTP as for real hardware.

**Add a hardware variation.** `bin/vm-create --nic virtio-net-pci --disk
virtio` (needs the virtio WinPE drivers and pack), `--vars` for a Secure
Boot-enforcing firmware image. **Add a VM-side probe:** `bin/vm-shot` and
`bin/vm-type` are the last resort; prefer a beacon from the machine.

**Prove it.** `bin/await <vm> <step>` makes every scenario scriptable; the
dated directories under `spikes/` are the record of which scenarios were run.

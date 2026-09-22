# Lab from scratch: iPXE + TFTP + DHCP + nginx for a batch of VMs on a host-only bridge

A hand-followable runbook. Start: a fresh Ubuntu 24.04 host with KVM and a
Windows 11 ISO. End: a batch of VMs on a host-only bridge that PXE-boot through
iPXE into WinPE and report back over HTTP. Everything lives under `/srv/pdt`
and runs as your normal user, except the bridge, dnsmasq and one setuid bit.

This is the lab the repo's `bin/` scripts will automate (PLAN.md §3). Doing it
by hand once is the fastest way to understand them. The boot chain (steps 5
to 10) is what `spikes/2026-09-22-wimboot-task-sequence/` verified; the bridge
and dnsmasq parts (steps 2, 3, 11) are standard but were written, not run,
when this file was committed. Tell the plan when you have run them.

Addresses used throughout: bridge `br0` = `10.42.0.1/24`, HTTP on port `8090`.
Change them consistently if they collide with something on your host.

## A. Host, once: packages, bridge, permissions

### 1. Packages

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils ovmf ipxe-qemu swtpm \
  dnsmasq nginx wimtools p7zip-full socat uuid-runtime \
  build-essential liblzma-dev git perl
sudo systemctl disable --now dnsmasq     # the packaged service; we run our own instance
```

`ipxe-qemu` provides the NIC option ROMs in `/usr/lib/ipxe/qemu/`. `ovmf`
provides the UEFI firmware in `/usr/share/OVMF/`.

### 2. Host-only bridge

No physical NIC is attached, so the VMs see only each other and the host.

```bash
sudo tee /etc/systemd/system/pdt-bridge.service >/dev/null <<'EOF'
[Unit]
Description=host-only bridge for the deployment lab
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link add br0 type bridge
ExecStart=/usr/sbin/ip addr add 10.42.0.1/24 dev br0
ExecStart=/usr/sbin/ip link set br0 up
ExecStop=/usr/sbin/ip link del br0
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now pdt-bridge
ip addr show br0      # expect 10.42.0.1/24, state UP
```

### 3. Let unprivileged QEMU attach to it

```bash
sudo mkdir -p /etc/qemu
echo 'allow br0' | sudo tee /etc/qemu/bridge.conf
ls -l /usr/lib/qemu/qemu-bridge-helper        # if it is not -rwsr-xr-x:
sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper
```

If a firewall is active: `sudo ufw allow in on br0` (or just UDP 67, UDP 69,
TCP 8090 on `br0`).

### 4. Directory layout

```bash
sudo mkdir -p /srv/pdt && sudo chown "$USER" /srv/pdt
mkdir -p /srv/pdt/{pxe,http/{winpe,tools,ts,machines},run,vms,build}
```

## B. The boot chain files

### 5. iPXE binary

Only needed for firmware that does not already carry an iPXE ROM: real
hardware, or OVMF without `romfile=`. It embeds one script that chains to the
DHCP server's HTTP script, so it never needs rebuilding per network.

```bash
cat > /srv/pdt/build/chain.ipxe <<'EOF'
#!ipxe
:retry
dhcp || goto wait
chain http://${next-server}:8090/boot.ipxe || shell
:wait
sleep 3
goto retry
EOF
git clone --depth 1 https://github.com/ipxe/ipxe.git /srv/pdt/build/ipxe
make -C /srv/pdt/build/ipxe/src bin-x86_64-efi/ipxe.efi EMBED=/srv/pdt/build/chain.ipxe -j"$(nproc)"
cp /srv/pdt/build/ipxe/src/bin-x86_64-efi/ipxe.efi /srv/pdt/pxe/
```

`${next-server}` is the DHCP server address iPXE learned. With dnsmasq on the
bridge that is `10.42.0.1`. Whether QEMU's user-mode network also fills it in
is unverified; on that path use the literal host as the v1 scripts do.

### 6. wimboot, pinned

```bash
curl -fL -o /srv/pdt/http/winpe/wimboot \
  https://github.com/ipxe/wimboot/releases/download/v2.9.0/wimboot
head -c2 /srv/pdt/http/winpe/wimboot   # MZ
```

### 7. WinPE files from the Windows 11 ISO (no mount, no sudo)

```bash
ISO=/path/to/win11.iso
7z l "$ISO" | grep -iE 'bootx64.efi|/bcd$|boot.sdi|boot.wim'   # confirm the paths
cd /srv/pdt/http/winpe
7z x "$ISO" efi/boot/bootx64.efi efi/microsoft/boot/bcd boot/boot.sdi sources/boot.wim
mv efi/boot/bootx64.efi bootmgfw.efi; mv efi/microsoft/boot/bcd BCD
mv boot/boot.sdi boot.sdi; mv sources/boot.wim boot.wim; rm -r efi boot sources
```

`boot.wim` stays untouched. Customisation is injected at boot by wimboot.

### 8. curl for WinPE

Stock WinPE has no HTTP client that can fetch binaries. Take the current win64
zip from <https://curl.se/windows/> and keep two files:

```bash
cd /srv/pdt/build && curl -fLO https://curl.se/windows/dl-8.22.0_1/curl-8.22.0_1-win64-mingw.zip
7z e -o/srv/pdt/http/tools curl-*-win64-mingw.zip 'curl-*/bin/curl.exe' 'curl-*/bin/libcurl-x64.dll'
ls /srv/pdt/http/tools      # curl.exe libcurl-x64.dll
```

### 9. The served iPXE scripts

The entry script is static. The identity goes on the chain URL's query string
only so nginx logs who booted (PLAN.md §3.2 derives the `ipxe` event from
that line). Unknown machines get a shell, never a wiping task sequence.

```bash
cat > /srv/pdt/http/boot.ipxe <<'EOF'
#!ipxe
set base http://10.42.0.1:8090
set who product=${product:uristring}&mac=${net0/mac}&serial=${serial:uristring}
chain ${base}/machines/${uuid}.ipxe?${who} || chain ${base}/default.ipxe?uuid=${uuid}&${who}
EOF
cat > /srv/pdt/http/default.ipxe <<'EOF'
#!ipxe
echo Machine ${uuid} (${product}) is not listed in machines/. Shell.
shell
EOF
cat > /srv/pdt/http/winpe.ipxe <<'EOF'
#!ipxe
set base http://10.42.0.1:8090
kernel ${base}/winpe/wimboot || shell
initrd --name bootmgfw.efi    ${base}/winpe/bootmgfw.efi
initrd --name BCD             ${base}/winpe/BCD
initrd --name boot.sdi        ${base}/winpe/boot.sdi
initrd --name boot.wim        ${base}/winpe/boot.wim
initrd --name winpeshl.ini    ${base}/ts/winpeshl.ini
initrd --name deploy.cmd      ${base}/ts/deploy.cmd
initrd --name curl.exe        ${base}/tools/curl.exe
initrd --name libcurl-x64.dll ${base}/tools/libcurl-x64.dll
boot || shell
EOF
```

### 10. A minimal task sequence

Proves the whole chain: WinPE up, network up, beacon, shell. The repo's real
`deploy.cmd` replaces this later.

```bash
printf '[LaunchApps]\r\n%%SYSTEMROOT%%\\System32\\cmd.exe, /k %%SYSTEMROOT%%\\System32\\deploy.cmd\r\n' \
  > /srv/pdt/http/ts/winpeshl.ini
cat > /srv/pdt/http/ts/deploy.cmd <<'EOF'
@echo off
set SRV=http://10.42.0.1:8090
wpeinit
:wait
ping -n 1 -w 1000 10.42.0.1 >nul 2>&1 && goto up
ping -n 2 127.0.0.1 >nul
goto wait
:up
for /f "tokens=2 delims==" %%u in ('wmic csproduct get UUID /value ^| find "="') do set ID=%%u
curl.exe -sS -G "%SRV%/beacon" --data-urlencode "id=%ID%" --data-urlencode "step=ts-start" --data-urlencode "ev=ok"
echo WinPE is up and the server has been told. Shell.
EOF
sed -i 's/$/\r/' /srv/pdt/http/ts/deploy.cmd
```

## C. Services and the VM batch

### 11. dnsmasq: real DHCP plus TFTP on the bridge

Nobody else hands out addresses on a host-only bridge, so dnsmasq is the
authoritative DHCP server (on a real LAN the repo uses proxy-DHCP instead; see
the end of this file). A firmware PXE client gets `ipxe.efi` over TFTP. A
client that is already iPXE (it sends DHCP option 175; QEMU's iPXE ROM does)
is handed the HTTP script directly and never touches TFTP.

```bash
cat > /srv/pdt/pxe/dnsmasq.conf <<'EOF'
interface=br0
bind-interfaces
port=0
dhcp-authoritative
dhcp-range=10.42.0.100,10.42.0.199,12h
dhcp-hostsfile=/srv/pdt/pxe/hosts.dhcp
enable-tftp
tftp-root=/srv/pdt/pxe
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-match=set:ipxe,175
dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi
dhcp-boot=tag:ipxe,http://10.42.0.1:8090/boot.ipxe
log-dhcp
log-facility=/srv/pdt/run/dnsmasq.log
EOF
touch /srv/pdt/pxe/hosts.dhcp
sudo dnsmasq --test -C /srv/pdt/pxe/dnsmasq.conf
sudo dnsmasq -C /srv/pdt/pxe/dnsmasq.conf --pid-file=/srv/pdt/run/dnsmasq.pid
```

`port=0` disables DNS so it stays clear of systemd-resolved. `log-dhcp` gives
the whole DHCP and TFTP conversation per MAC.

### 12. nginx, rootless, bound to the bridge

```bash
cat > /srv/pdt/run/nginx.conf <<'EOF'
pid /srv/pdt/run/nginx.pid;
error_log /srv/pdt/run/error.log warn;
events { worker_connections 256; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  client_body_temp_path /srv/pdt/run/tmp; proxy_temp_path /srv/pdt/run/tmp;
  fastcgi_temp_path /srv/pdt/run/tmp; uwsgi_temp_path /srv/pdt/run/tmp; scgi_temp_path /srv/pdt/run/tmp;
  log_format access '$remote_addr [$time_local] "$request" $status $body_bytes_sent $request_time';
  log_format beacon '$time_iso8601 $msec $remote_addr $args';
  access_log /srv/pdt/run/access.log access;
  sendfile on; tcp_nopush on;
  server {
    listen 10.42.0.1:8090;
    root /srv/pdt/http;
    location = /beacon { access_log /srv/pdt/run/beacons.log beacon; return 200 "ok\n"; }
  }
}
EOF
mkdir -p /srv/pdt/run/tmp
nginx -t -c /srv/pdt/run/nginx.conf -p /srv/pdt/run && nginx -c /srv/pdt/run/nginx.conf -p /srv/pdt/run
curl -s http://10.42.0.1:8090/boot.ipxe | head -1     # #!ipxe
```

Stop it later with `nginx -s quit -c /srv/pdt/run/nginx.conf -p /srv/pdt/run`.

### 13. The batch table

Every VM gets a fixed MAC, a fixed SMBIOS UUID and a fixed IP. QEMU's default
UUID is all zeros, so without `-uuid` every VM is the same machine and the
per-machine config cannot tell them apart.

```bash
cat > /srv/pdt/vms.tsv <<EOF
vm01	52:54:00:42:00:01	$(uuidgen)	10.42.0.11
vm02	52:54:00:42:00:02	$(uuidgen)	10.42.0.12
vm03	52:54:00:42:00:03	$(uuidgen)	10.42.0.13
EOF

# generate dnsmasq leases, per-machine boot scripts, and per-VM disk + NVRAM
: > /srv/pdt/pxe/hosts.dhcp
while IFS=$'\t' read -r name mac uuid ip; do
  echo "$mac,$ip,$name" >> /srv/pdt/pxe/hosts.dhcp
  printf '#!ipxe\nchain http://10.42.0.1:8090/winpe.ipxe\n' > "/srv/pdt/http/machines/$uuid.ipxe"
  [ -f "/srv/pdt/vms/$name.qcow2" ] || qemu-img create -f qcow2 "/srv/pdt/vms/$name.qcow2" 64G
  [ -f "/srv/pdt/vms/$name-vars.fd" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "/srv/pdt/vms/$name-vars.fd"
done < /srv/pdt/vms.tsv
sudo kill -HUP "$(cat /srv/pdt/run/dnsmasq.pid)"     # re-read hosts.dhcp
```

Remove a machine's `.ipxe` file and it gets the shell instead of WinPE. That
is the allow-list.

### 14. Launch

One script, one VM per row, staggered so they do not all pull the 500 MB
`boot.wim` in the same second. Monitor port `7000 + N` per VM.

```bash
cat > /srv/pdt/vm-boot <<'EOF'
#!/bin/bash
# usage: vm-boot <name>      (from /srv/pdt/vms.tsv)
set -eu
read -r name mac uuid ip n < <(awk -v n="$1" '$1==n{print $1,$2,$3,$4,NR}' /srv/pdt/vms.tsv)
nohup qemu-system-x86_64 -enable-kvm -cpu host -machine q35,smm=on -m 4G -smp 4 \
  -uuid "$uuid" -smbios type=1,manufacturer=PDT,product=lab-vm,serial="$name" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,unit=1,file="/srv/pdt/vms/$name-vars.fd" \
  -drive file="/srv/pdt/vms/$name.qcow2",format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,bootindex=1 \
  -netdev bridge,id=net0,br=br0 \
  -device e1000e,netdev=net0,mac="$mac",romfile=/usr/lib/ipxe/qemu/efi-e1000e.rom,bootindex=2 \
  -display none -monitor tcp:127.0.0.1:$((7000+n)),server,nowait \
  > "/srv/pdt/run/$name.qemu.log" 2>&1 &
echo "$name pid $! monitor 127.0.0.1:$((7000+n))"
EOF
chmod +x /srv/pdt/vm-boot
cut -f1 /srv/pdt/vms.tsv | while read -r v; do /srv/pdt/vm-boot "$v"; sleep 5; done
```

`e1000e` because WinPE drives it inbox. The Secure Boot capable firmware with
the empty variables template is Setup Mode: capable, not enforcing, so the
unsigned `ipxe.efi` loads. No TPM is attached; the DISM apply path does not
need one (add swtpm per VM only if you go back to `setup.exe`).

To also test the path real firmware takes (TFTP, then our `ipxe.efi`), drop
`romfile=...` from one VM: OVMF's own PXE stack then fetches `ipxe.efi` and
the embedded script from step 5 does the chaining.

### 15. Watch it work, layer by layer

```bash
sudo tcpdump -ni br0 'port 67 or port 69' -c 20   # DISCOVER/OFFER; TFTP only on the no-ROM path
tail -f /srv/pdt/run/dnsmasq.log                   # which tag matched, which file or URL was handed out
tail -f /srv/pdt/run/access.log                    # boot.ipxe, machines/<uuid>.ipxe?product=..., wimboot, boot.wim with bytes and seconds
tail -f /srv/pdt/run/beacons.log                   # id=<uuid> step=ts-start from WinPE
printf 'screendump /srv/pdt/run/vm01.ppm\n' | socat -t2 - TCP:127.0.0.1:7001   # look at a screen
```

When `beacons.log` shows `ts-start` from every UUID in `vms.tsv`, the network
side is done. Everything after it is the task sequence: the repo's
`deploy.cmd` steps, images, drivers, unattend (PLAN.md §4, Phase 2).

## D. Two things before you extend this

- **No internet on a host-only bridge.** When a later phase needs it (winget
  at first logon), add `sysctl net.ipv4.ip_forward=1`, one
  `iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o <uplink> -j MASQUERADE`,
  and `dhcp-option=option:router,10.42.0.1` plus a DNS option in dnsmasq.
- **On a real LAN** the router owns addresses, so replace step 11's
  authoritative form with proxy-DHCP (`dhcp-range=<subnet>,proxy`, no
  `dhcp-range` leases, no `dhcp-hostsfile`), as `scripts/07-setup-physical.sh`
  does today. Everything else stays identical. That is the point of putting
  the identity logic in `boot.ipxe` rather than in the compiled binary.

## Mapping to the repo

| this runbook | repo (PLAN.md §3) |
|---|---|
| step 5 | `bin/build-ipxe` (chain to `${next-server}`, no per-network rebuild) |
| steps 6, 8 | `bin/fetch-tools` (pinned, hash-checked) |
| step 7 | `bin/stage-winpe` (7z, no sudo) |
| step 9 | `http/boot.ipxe`, `http/default.ipxe`, `http/machines/<uuid>.ipxe` |
| step 11 | `bin/pxe-lan --bridge` (authoritative) vs `bin/pxe-lan` (proxy) |
| step 12 | `bin/serve` (+ `PUT /uploads/` from §3.2) |
| steps 13, 14 | `vms.tsv` read by `bin/vm-create` and `bin/vm-boot`; `bin/vm-shot` |
| step 15 | `bin/status`, `bin/timeline`, `bin/await` over `beacons.log` |

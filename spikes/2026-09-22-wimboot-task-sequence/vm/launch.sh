#!/bin/bash
# launch.sh - start the throwaway spike VM headless; PID -> vm/qemu.pid
S=/tmp/claude-1000/-home-sqs-scripts-Windows-install-via-Linux/db333f61-18fb-420a-8c91-36dad1f2e3d0/scratchpad
MP=$(awk '{print $3}' $S/vm/monport)
nohup qemu-system-x86_64 -enable-kvm -cpu host -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s3=1 -m 4G -smp 4 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,unit=1,file=$S/vm/vars.fd \
  -drive file=$S/vm/spike.qcow2,format=qcow2,if=none,id=hd0 -device ide-hd,drive=hd0,bus=ide.0,bootindex=1 \
  -netdev user,id=net0,tftp=$S/tftp,bootfile=ipxe.efi \
  -device ${NIC:-e1000e},netdev=net0,romfile=/usr/lib/ipxe/qemu/efi-${NICROM:-e1000e}.rom,bootindex=2 \
  -display none -monitor tcp:127.0.0.1:$MP,server,nowait -serial file:$S/vm/serial.log \
  > $S/vm/qemu.out 2>&1 &
echo $! > $S/vm/qemu.pid
sleep 2; kill -0 $(cat $S/vm/qemu.pid) 2>/dev/null && echo "qemu pid $(cat $S/vm/qemu.pid) running" || { echo "qemu failed:"; cat $S/vm/qemu.out; exit 1; }

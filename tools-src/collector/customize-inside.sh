# customize-inside.sh - run INSIDE the chroot by mmdebstrap (as its
# --chrooted-customize-hook, passed inline: this host's AppArmor profile for
# mmdebstrap lets hooks run only as shell strings, not as files).
set -eu
echo pdt-collector > /etc/hostname
printf '127.0.1.1 pdt-collector\n' >> /etc/hosts
# root: key only, no password (the account stays locked for passwords).
mkdir -p /root/.ssh; chmod 700 /root/.ssh
mv /root/.ssh_authorized_keys /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
cat > /etc/ssh/sshd_config.d/pdt.conf <<'SSH'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
SSH
# Host keys are generated at first boot by sshd's own unit (ssh-keygen -A),
# so every boot of the RAM image gets fresh ones; nothing to bake.
rm -f /etc/ssh/ssh_host_*
systemctl enable systemd-networkd systemd-resolved ssh pdt-sshkeys pdt-collect >/dev/null 2>&1
systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
# The kernel runs /init: systemd, directly (no /etc/initrd-release, so a
# normal boot on the RAM root the kernel unpacked us into).
ln -sf sbin/init /init
# A console on the serial port too (machines with one, and QEMU -serial).
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
# Smaller: no docs, manuals, locales, apt caches; the kernel's own initrd is
# not needed (we ARE the initramfs), nor the /boot symlinks.
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/* \
       /var/cache/apt/* /var/lib/apt/lists/* /boot/initrd.img-* /initrd.img* /vmlinuz*
dpkg-query -W -f '${Package} ${Version}\n' > /etc/pdt-packages.txt
dpkg -L amtterm | grep bin/ > /etc/pdt-amtterm-bins.txt || true
chmod 755 /usr/local/bin/*
# copy-in keeps the host owner; inside the image everything is root's.
chown -R 0:0 /usr/local/bin /etc/systemd/system/pdt-collect.service /etc/systemd/system/pdt-sshkeys.service /etc/systemd/system/ssh.service.d /etc/systemd/network/20-ethernet.network /root

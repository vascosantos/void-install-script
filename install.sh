#!/usr/bin/bash
source env.conf

XBPS_ARCH=x86_64 xbps-install -S -r /mnt -R $REPO_URL ${PKGS}

mount -t efivarfs efivarfs /sys/firmware/efi/efivars
for mount in sys dev proc; do mount --rbind /$mount /mnt/$mount; done

useradd -R /mnt -mG $USER_GROUPS $USER_NAME
passwd -R /mnt root
passwd -R /mnt $USER_NAME
chown root:root /mnt
chmod 755 /mnt
sed -i "/GETTY_ARGS=/s/\"$/ --autologin $USER_NAME&/" /mnt/etc/sv/agetty-tty1/conf
sed -i '/^.*pam_dumb_runtime.*/s/.//' /mnt/etc/pam.d/system-login
echo $HOST_NAME > /mnt/etc/hostname
chroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
sed -i "/^#$LOCALE/s/.//" /mnt/etc/default/libc-locales
mkdir -pv /mnt/etc/sysctl.d
echo "kernel.dmesg_restrict=0" > /mnt/etc/sysctl.d/99-dmesg-user.conf

cat <<EOFSTAB > /mnt/etc/fstab
UUID=${EFI_UUID} /boot/efi vfat defaults 0 2
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPTS},subvol=@ 0 0
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPTS},subvol=@home 0 0
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPTS},subvol=@snapshots 0 0
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPTS},subvol=@/var/log 0 0
/var/@swap/swapfile none swap sw 0 0
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
EOFSTAB
cat <<EODOASCONF > /mnt/etc/doas.conf
permit persist $USER_NAME
permit nopass $USER_NAME cmd xbps-install
EODOASCONF
cat <<EOMODPROBENVIDIACONF > /mnt/etc/modprobe.d/nvidia.conf
blacklist nouveau
options nvidia-drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
EOMODPROBENVIDIACONF
cat <<EODRACUTCONF > /mnt/etc/dracut.conf.d/options.conf
hostonly=yes
hostonly_cmdline=yes
show_modules=yes
compress="cat"
EODRACUTCONF
cat <<EOEFISTUB > /mnt/etc/default/efibootmgr-kernel-hook
MODIFY_EFI_ENTRIES=1
OPTIONS="rw mitigations=off loglevel=6 nowatchdog"
DISK=$DISK
PART=1
EOEFISTUB

mkdir -p /mnt/etc/xbps.d
xbps-install -Sy -r /mnt -R $REPO_URL $EXTRAREPOS
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf
for service in acpid dhcpcd socklog-unix nanoklogd dbus bluetoothd; do
  chroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done
xbps-install -r /mnt -Syuv $PACKAGES
xbps-reconfigure -r /mnt -fa
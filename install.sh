#!/usr/bin/bash

#
# This script installs Void Linux on a ZFS filesystem.
#
# It features:
#   - UEFI boot with ZFSBootMenu
#   - ZFS root filesystem
#   - Zram swap space
#   - NetworkManager and elogind
#   - Proprietary Nvidia drivers
#   - Gnome desktop environment
#   - Flatpak support
#   - AppArmor
#
# Tested on a desktop PC using a wired Ethernet connection, Intel CPU (i7-12900K) and Nvidia GPU (GTX 1650 SUPER). 
# This is based on the hrmpf rescue system image release 20250228 (https://github.com/leahneukirchen/hrmpf).
#
# PLEASE HANDLE WITH CARE AS ALL CONTENTS ON THE SELECTED DISK WILL BE LOST
#

# Global variables
BOOT_DISK=/dev/vda
POOL_DISK=/dev/vda
BOOT_PARTITION=1
POOL_PARTITION=2
KEYMAP=us-acentos
TIME_ZONE=Europe/Lisbon
ARCH=x86_64
REPO=https://repo-default.voidlinux.org
USER_NAME=vasco
HOST_NAME=morpheus
ZRAM_COMPRESSOR=zstd    # zram compression algorithm (see https://github.com/atweiden/zramen/blob/master/zramen or check `man zramctl`)
ZRAM_INIT_SIZE_PCT=2    # initial zram size as a percentage of total RAM
ZRAM_MAX_SIZE_MB=16384  # maximum zram size in MB

# Set boot and pool devices
if [[ $BOOT_DISK == *"nvme"* ]]; then
  BOOT_DEVICE="${BOOT_DISK}p${BOOT_PARTITION}"
else
  BOOT_DEVICE="${BOOT_DISK}${BOOT_PARTITION}"
fi
if [[ $POOL_DISK == *"nvme"* ]]; then
  POOL_DEVICE="${POOL_DISK}p${POOL_PARTITION}"
else
  POOL_DEVICE="${POOL_DISK}${POOL_PARTITION}"
fi

# Generate /etc/hostid
ID="void"
zgenhostid -f 0x00bab10c

# Wipe all partitions
zpool labelclear -f "$POOL_DISK"
wipefs -a "$POOL_DISK"
wipefs -a "$BOOT_DISK"
sgdisk --zap-all "$POOL_DISK"
sgdisk --zap-all "$BOOT_DISK"

# Create partitions
sgdisk -n "${BOOT_PARTITION}:1m:+512m" -t "${BOOT_PARTITION}:ef00" "$BOOT_DISK"
sgdisk -n "${POOL_PARTITION}:0:-10m" -t "${POOL_PARTITION}:bf00" "$POOL_DISK"
mkfs.vfat -F32 "$BOOT_DEVICE"

# Create the zpool
zpool create -f -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O relatime=on \
    -o autotrim=on \
    -o compatibility=openzfs-2.3-linux \
    -m none zroot "$POOL_DEVICE"

# Create initial file systems
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home
zpool set bootfs=zroot/ROOT/${ID} zroot

# Export and re-import the pool to mount the root filesystem
zpool export zroot
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/${ID}
zfs mount zroot/home

# Update device symlinks
udevadm trigger

# Update XBPS
XBPS_ARCH=$ARCH xbps-install -Sy xbps

# Install base system and some basic packages
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" base-system
for dir in sys dev proc; do 
    mount --rbind /$dir /mnt/$dir; mount --make-rslave /mnt/$dir; 
done
cp -L /etc/resolv.conf /mnt/etc/
cp -L /etc/hostid /mnt/etc/

# Set hostname, timezone and locales
echo $HOST_NAME > /mnt/etc/hostname
xchroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/default/libc-locales
XBPS_ARCH=$ARCH xbps-reconfigure -r /mnt -f glibc-locales

# Set keymap
sed -i "/#KEYMAP=/s/.*/KEYMAP=\"$KEYMAP\"/" /mnt/etc/rc.conf

# Set root password
echo "-> Set password for root"
passwd root -R /mnt

# Create user and groups, and set password
groupadd -R /mnt socklog
groupadd -R /mnt libvirt
groupadd -R /mnt docker
groupadd -R /mnt bluetooth
groupadd -R /mnt lpadmin
useradd -R /mnt -mG wheel,input,kvm,socklog,libvirt,docker,audio,video,network,bluetooth,lpadmin $USER_NAME
echo "-> Set password for $USER_NAME"
passwd $USER_NAME -R /mnt

# Set ownership and permissions, and enable sudo for wheel group
chown root:root /mnt
chmod 755 /mnt
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/10-wheel.conf
echo "%wheel ALL= (ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /sbin/halt" >> /mnt/etc/sudoers.d/10-wheel.conf # allow shutdown, reboot and halt without password
echo "Defaults timestamp_timeout=60" >> /mnt/etc/sudoers.d/10-wheel.conf    # require password only every 60 minutes (default is 5)

# Configure zram swap
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt zramen
sed -i "s/.*ZRAM_COMP_ALGORITHM.*/export ZRAM_COMP_ALGORITHM=$ZRAM_COMPRESSOR/g" /mnt/etc/sv/zramen/conf
sed -i "s/.*ZRAM_SIZE.*/export ZRAM_SIZE=$ZRAM_INIT_SIZE_PCT/g" /mnt/etc/sv/zramen/conf
sed -i "s/.*ZRAM_MAX_SIZE.*/export ZRAM_MAX_SIZE=$ZRAM_MAX_SIZE_MB/g" /mnt/etc/sv/zramen/conf
echo "add_drivers+=\" zram \"" >> /mnt/etc/dracut.conf.d/10-add_zram_driver.conf

# Install repositories
mkdir -p /mnt/etc/xbps.d
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree 

# Set repository mirrors
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf

# Install intel-ucode and nvidia drivers
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy intel-ucode mesa-dri nvidia

# Configure nvidia and dracut
cat <<EOMODPROBENVIDIACONF >> /mnt/etc/modprobe.d/nvidia.conf
# blacklist nouveau
options nvidia-drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
EOMODPROBENVIDIACONF
cat <<EODRACUTCONF >> /mnt/etc/dracut.conf.d/options.conf
hostonly="yes"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
EODRACUTCONF

# Some nvidia fixes
mkdir -p /mnt/udev/rules.d
xchroot /mnt ln -s /dev/null /etc/udev/rules.d/61-gdm.rules

# Install extra packages
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy NetworkManager apparmor bluez pipewire gnome gnome-software xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome cups foomatic-db foomatic-db-nonfree avahi nss-mdns dejavu-fonts-ttf xorg-fonts noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji nerd-fonts autorestic snapper bash-completion vim 

# Configure flatpak
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy flatpak
xchroot /mnt flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install and configure ZFSBootMenu
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy zfs zfsbootmenu efibootmgr systemd-boot-efistub zfs-auto-snapshot

xchroot /mnt zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT
cat << EOF >> /mnt/etc/fstab
$( blkid | grep "$BOOT_DEVICE" | cut -d ' ' -f 2 ) /boot/efi vfat defaults 0 0
EOF

mkdir -p /mnt/boot/efi
mount -t vfat $BOOT_DEVICE /mnt/boot/efi

cat << EOZFSBMCFG > /mnt/etc/zfsbootmenu/config.yaml
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
Components:
   Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/zbm
  Versions: false
  Enabled: true
Kernel:
  CommandLine: quiet loglevel=0 apparmor=1 security=apparmor
EOZFSBMCFG

xchroot /mnt generate-zbm  # generate ZFSBootMenu image

xchroot /mnt efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PARTITION" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

xchroot /mnt efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PARTITION" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'

xchroot /mnt dracut --regenerate-all --force

# Install services
for service in elogind NetworkManager socklog-unix nanoklogd dbus avahi-daemon bluetoothd gdm cupsd zramen; do
  xchroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done

# Don't start GDM by default, just in case the video drivers are not working
touch /mnt/etc/sv/gdm/down

# Change vm.swappiness
mkdir -p /mnt/etc/sysctl.conf.d
echo "vm.swappiness = 10" >> /mnt/etc/sysctl.conf.d/99-swappiness.conf

# Customize .bashrc
echo "alias la='ll -a'" >> /mnt/home/$USER_NAME/.bashrc
echo "alias xin='sudo xbps-install'" >> /mnt/home/$USER_NAME/.bashrc
echo "alias xq='xbps-query -Rs'" >> /mnt/home/$USER_NAME/.bashrc
echo "alias xr='sudo xbps-remove'" >> /mnt/home/$USER_NAME/.bashrc
echo "alias xro='sudo xbps-remove -o'" >> /mnt/home/$USER_NAME/.bashrc

# Reconfigure all packages
xchroot /mnt xbps-reconfigure -fa

# Unmount all filesystems
umount -n -R /mnt

# Export zpool and prepare for reboot
zpool export zroot
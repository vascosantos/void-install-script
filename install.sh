#!/usr/bin/bash

#
# This script installs Void Linux on a ZFS filesystem, a Gnome desktop environment and some basic packages.
# It configures the system for zram swap space, and uses NetworkManager and elogind.
# Tested on a desktop PC using a wired Ethernet connection, Intel CPU (i7-12900K) and Nvidia GPU (GTX 1650 SUPER). 
# This is based on the hrmpf rescue system image release 20250228 (https://github.com/leahneukirchen/hrmpf).
#
# PLEASE HANDLE WITH CARE AS ALL CONTENTS ON THE SELECTED DISK WILL BE LOST
#

# Global variables
DISK=/dev/vda
BTRFS_OPT=rw,noatime,ssd,discard=async,compress-force=zstd:1,space_cache=v2,commit=120
KEYMAP=us-acentos
TIME_ZONE=Europe/Lisbon
ARCH=x86_64
REPO=https://repo-default.voidlinux.org
USER_NAME=vasco
HOST_NAME=morpheus
ZRAM_COMPRESSOR=zstd    # zram compression algorithm (see https://github.com/atweiden/zramen/blob/master/zramen or check `man zramctl`)
ZRAM_INIT_SIZE_PCT=2    # initial zram size as a percentage of total RAM
ZRAM_MAX_SIZE_MB=16384  # maximum zram size in MB

# Update Void
xbps-install -Suy   # might need to run twice to ensure all packages are up-to-date
xbps-install -Suy

# Install gptfdisk on the live system
xbps-install -Sy gptfdisk

# Perform disk partitioning - ALL CONTENTS WILL BE LOST
sgdisk -Z ${DISK}
sgdisk -a 2048 -o ${DISK}
sgdisk -n 1:0:+512M ${DISK} # /dev/sda1
sgdisk -n 2:0:0 ${DISK}     # /dev/sda2
sgdisk -t 1:ef00 ${DISK} 
sgdisk -t 2:8300 ${DISK} 
mkfs.vfat -F 32 -n EFI ${DISK}1
mkfs.btrfs -L Void -f ${DISK}2

# Mount partitions and create subvolumes
mount -o $BTRFS_OPT ${DISK}2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt
mount -o $BTRFS_OPT,subvol=@ ${DISK}2 /mnt
mkdir /mnt/home
mkdir /mnt/.snapshots
mount -o $BTRFS_OPT,subvol=@home ${DISK}2 /mnt/home/
mkdir -p /mnt/boot/efi
mount -o rw,noatime ${DISK}1 /mnt/boot/efi/
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/log

# Install base system and some basic packages
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" base-system btrfs-progs grub-x86_64-efi grub-btrfs grub-btrfs-runit NetworkManager zramen
for dir in sys dev proc; do 
    mount --rbind /$dir /mnt/$dir; mount --make-rslave /mnt/$dir; 
done
cp -L /etc/resolv.conf /mnt/etc/

# Set hostname, timezone and locales
echo $HOST_NAME > /mnt/etc/hostname
chroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
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

# Write fstab
export BOOT_UUID=$(blkid -s UUID -o value ${DISK}1)
export ROOT_UUID=$(blkid -s UUID -o value ${DISK}2)

cat <<EOFSTAB >> /mnt/etc/fstab
UUID=$BOOT_UUID /boot/efi   vfat    defaults                        0 2
UUID=$ROOT_UUID /           btrfs   $BTRFS_OPT,subvol=@             0 0
UUID=$ROOT_UUID /home       btrfs   $BTRFS_OPT,subvol=@home         0 0
UUID=$ROOT_UUID /.snapshots btrfs   $BTRFS_OPT,subvol=@snapshots    0 0
UUID=$ROOT_UUID /var/log    btrfs   $BTRFS_OPT,subvol=@/var/log     0 0
tmpfs           /tmp        tmpfs   defaults,noatime,mode=1777      0 0
EOFSTAB

# Configure zram swap
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

# Configure nvidia, dracut and efibootmgr
cat <<EOMODPROBENVIDIACONF >> /mnt/etc/modprobe.d/nvidia.conf
# blacklist nouveau
options nvidia-drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
EOMODPROBENVIDIACONF
cat <<EODRACUTCONF >> /mnt/etc/dracut.conf.d/options.conf
hostonly=yes
EODRACUTCONF

# Some nvidia fixes
mkdir -p /mnt/udev/rules.d
chroot /mnt ln -s /dev/null /etc/udev/rules.d/61-gdm.rules

# Install extra packages
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy apparmor bluez pipewire gnome gnome-software xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome cups foomatic-db foomatic-db-nonfree avahi nss-mdns dejavu-fonts-ttf xorg-fonts noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji nerd-fonts autorestic flatpak snapper bash-completion vim 

# Enable AppArmor
sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ apparmor=1 security=apparmor&/" /mnt/etc/default/grub

# Configure flatpak
chroot /mnt flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install Grub and generate initramfs 
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars
chroot /mnt grub-install --target=x86_64-efi --boot-directory=/boot --efi-directory=/boot/efi --bootloader-id="Void Linux" --recheck
chroot /mnt dracut --regenerate-all --force
chroot /mnt update-grub

# Install services
for service in elogind NetworkManager socklog-unix nanoklogd dbus avahi-daemon bluetoothd gdm cupsd grub-btrfs zramen; do
  chroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done

# Don't start GDM by default, just in case the video drivers are not working
touch /mnt/etc/sv/gdm/down

# Set up snapper
rm -r /mnt/.snapshots
chroot /mnt snapper -c root create-config /
btrfs subvolume delete /mnt/.snapshots
mkdir /mnt/.snapshots

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
chroot /mnt xbps-reconfigure -fa
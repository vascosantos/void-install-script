#!/usr/bin/bash

DISK=/dev/vda
export BTRFS_OPT=rw,noatime,discard=async,compress-force=zstd:1,space_cache=v2,commit=120
KEYMAP=us-acentos
TIME_ZONE=Europe/Lisbon
export ARCH=x86_64
export REPO=https://repo-default.voidlinux.org/current

loadkeys $KEYMAP

mount -t efivarfs efivarfs /sys/firmware/efi/efivars

wipefs --all $DISK
(
    echo g   # Create a new GPT partition table
    echo n   # Create EFI partition
    echo 1   # Partition number
    echo     # Default start sector
    echo +512M  # Partition size
    echo t   # Change partition type
    echo 1   # Select partition 1
    echo ef  # Set type to EFI System (EF00)

    echo n   # Create root partition
    echo 2   # Partition number
    echo     # Default start sector
    echo     # Use the remaining space
    echo t   # Change partition type
    echo 2   # Select partition 2
    echo 83  # Set type to Linux Filesystem (8300)

    echo w   # Write changes and exit
) | fdisk $DISK
# fdisk $DISK <<EOFDISK
# g   # Create a new GPT partition table

# n   # Create EFI partition
# 1   # Partition number
#     # Default start sector
# +512M  # Partition size
# t   # Change partition type
# 1   # Select partition 1
# ef  # Set type to EFI System (EF00)

# n   # Create root partition
# 2   # Partition number
#     # Default start sector
#     # Use the remaining space
# t   # Change partition type
# 2   # Select partition 2
# 83  # Set type to Linux Filesystem (8300)

# w   # Write changes and exit
# EOFDISK

mkfs.vfat -n EFI -F 32 ${DISK}1
mkfs.btrfs -L Void ${DISK}2

mount -o $BTRFS_OPT ${DISK}2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt
mount -o $BTRFS_OPT,subvol=@ ${DISK}2 /mnt
mkdir /mnt/home
mkdir /mnt/.snapshots
mount -o $BTRFS_OPT,subvol=@home ${DISK}2 /mnt/home/
mount -o $BTRFS_OPT,subvol=@snapshots ${DISK}2 /mnt/.snapshots/
mkdir -p /mnt/boot/efi
mount -o rw,noatime ${DISK}1 /mnt/boot/efi/
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/log

XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" base-system btrfs-progs grub-x86_64-efi grub-btrfs grub-btrfs-runit NetworkManager bash-completion vim wget gcc
for dir in sys dev proc; do mount --rbind /$dir /mnt/$dir; mount --make-rslave /mnt/$dir; done
cp -L /etc/resolv.conf /mnt/etc/

echo morpheus > /mnt/etc/hostname
chroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/default/libc-locales
mkdir -pv /mnt/etc/sysctl.d
echo "kernel.dmesg_restrict=0" > /mnt/etc/sysctl.d/99-dmesg-user.conf

passwd root -R /mnt
useradd -R /mnt -mG wheel,input,kvm,socklog,libvirt,docker,audio,video,network,bluetooth vasco
chown root:root /mnt
chmod 755 /mnt
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/10-wheel

export BOOT_UUID=$(blkid -s UUID -o value ${DISK}1)
export ROOT_UUID=$(blkid -s UUID -o value ${DISK}2)

cat <<EOFSTAB > /mnt/etc/fstab
UUID=$BOOT_UUID /boot/efi   vfat    defaults                        0 2
UUID=$ROOT_UUID /           btrfs   $BTRFS_OPT,subvol=@             0 0
UUID=$ROOT_UUID /home       btrfs   $BTRFS_OPT,subvol=@home         0 0
#UUID=$ROOT_UUID /.snapshots btrfs   $BTRFS_OPT,subvol=@snapshots    0 0
UUID=$ROOT_UUID /var/log    btrfs   $BTRFS_OPT,subvol=@/var/log     0 0
tmpfs           /tmp        tmpfs   defaults,noatime,mode=1777      0 0
EOFSTAB


mkdir -p /mnt/etc/xbps.d
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" void-repo-multilib void-repo-multilib-nonfree void-repo-nonfree
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/

sed -i "s|https://repo-default.voidlinux.org|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf
for service in acpid dhcpcd socklog-unix nanoklogd dbus bluetoothd; do
  chroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done
xbps-install -r /mnt -Syuv intel-ucode nvidia
xbps-reconfigure -r /mnt -fa


BTRFS_OPTS=$BTRFS_OPTS PS1='(chroot) # ' chroot /mnt/ /bin/bash
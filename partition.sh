#!/usr/bin/bash
source env.conf

wipefs --all ${DISK}
fdisk ${DISK} <<EOFDISK
g   # Create a new GPT partition table

n   # Create EFI partition
1   # Partition number
    # Default start sector
+512M  # Partition size
t   # Change partition type
1   # Select partition 1
ef  # Set type to EFI System (EF00)

n   # Create root partition
2   # Partition number
    # Default start sector
    # Use the remaining space
t   # Change partition type
2   # Select partition 2
83  # Set type to Linux Filesystem (8300)

w   # Write changes and exit
EOFDISK

mkfs.vfat -F 32 -n ${EFI_LABEL} ${DISK}1
mkfs.btrfs -L ${ROOT_LABEL} -f ${DISK}2
mount -o ${BTRFS_OPTS} ${DISK}2 /mnt
mkdir -pv /mnt/boot/efi
mount -o noatime ${DISK}1 /mnt/boot/efi

mount -o ${BTRFS_OPTS} ${DISK}2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt
mount -o ${BTRFS_OPTS},subvol=@ ${DISK}2 /mnt
mkdir /mnt/home
mount -o ${BTRFS_OPTS},subvol=@home ${DISK}2 /mnt/home/
mkdir /mnt/swap
mount -o ${BTRFS_OPTS},subvol=@swap ${DISK}2 /mnt/swap/
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/log

truncate -s 0 /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile
btrfs property set /mnt/swap/swapfile compression none
dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=${SWAP_SIZE_MB} status=progress
chmod 0600 /mnt/swap/swapfile
mkswap -U clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

export RESUME_UUID=$(findmnt -no UUID -T /mnt/swap/swapfile)
export RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ resume=UUID=${RESUME_UUID} resume_offset=${RESUME_OFFSET}&/" /mnt/etc/default/grub

export EFI_UUID=$(blkid -s UUID -o value "${DISK}1")
export ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
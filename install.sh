#!/usr/bin/bash

KEYMAP=us-acentos
DISK=/dev/vda

loadkeys $KEYMAP

mount -t efivarfs efivarfs /sys/firmware/efi/efivars

wipefs --all $DISK
fdisk $DISK <<EOFDISK
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

mkfs.vfat -n EFI -F 32 ${DISK}1
mkfs.btrfs -L Void ${DISK}2

export BTRFS_OPT=rw,noatime,discard=async,compress-force=zstd:1,space_cache=v2,commit=120
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
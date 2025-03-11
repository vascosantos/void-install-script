#!/usr/bin/bash
source env.conf

sgdisk -Z ${DISK}
sgdisk -a 2048 -o ${DISK}
sgdisk -n 1:0:+512M ${DISK} # /dev/sda1
sgdisk -n 2:0:0 ${DISK} # /dev/sda2
mkfs.vfat -F 32 -n ${EFI_LABEL} ${DISK}1
mkfs.btrfs -L ${ROOT_LABEL} -f ${DISK}2
sgdisk -t 1:ef00 ${DISK} 
sgdisk -t 2:8300 ${DISK} 
mount -o ${BTRFS_OPTS} ${DISK}2 /mnt
mkdir -pv /mnt/boot/efi
mount -o noatime ${DISK}1 /mnt/boot/efi

btrfs sub create /mnt/var/@swap
truncate -s 0 /mnt/var/swap/swapfile
chattr +C /mnt/var/swap/swapfile
btrfs property set /mnt/var/swap/swapfile compression none
dd if=/dev/zero of=/mnt/var/swap/swapfile bs=1M count=$SWAP_SIZE_MB status=progress
chmod 0600 /mnt/var/swap/swapfile
mkswap -U clear /mnt/var/swap/swapfile
swapon /mnt/var/swap/swapfile

RESUME_UUID=$(findmnt -no UUID -T /mnt/var/swap/swapfile)
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/var/swap/swapfile)
if [[ $bootloader =~ $regex_EFISTUB ]]; then
    sed -i "/OPTIONS=/s/\"$/ resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET&/" /mnt/etc/default/efibootmgr-kernel-hook
elif [[ $bootloader =~ $regex_GRUB2 ]]; then
    sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ resume=UUID=$RESUME_UUID resume_offset=$RESUME_OFFSET&/" /mnt/etc/default/grub
fi

export EFI_UUID=$(blkid -s UUID -o value "${DISK}1")
export ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
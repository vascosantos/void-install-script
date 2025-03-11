#!/usr/bin/bash

# Global variables
DISK=/dev/vda
export BTRFS_OPT=rw,noatime,discard=async,compress-force=zstd:1,space_cache=v2,commit=120
KEYMAP=us-acentos
TIME_ZONE=Europe/Lisbon
export ARCH=x86_64
export REPO=https://repo-default.voidlinux.org

# Disk partitioning
wipefs --all $DISK
(
    echo g   # Create a new GPT partition table
    echo n   # Create EFI partition
    echo 1   # Partition number
    echo     # Default start sector
    echo +512M  # Partition size
    echo t   # Change partition type
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
mkfs.vfat -n EFI -F 32 ${DISK}1
mkfs.btrfs -L Void ${DISK}2

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
mount -o $BTRFS_OPT,subvol=@snapshots ${DISK}2 /mnt/.snapshots/
mkdir -p /mnt/boot/efi
mount -o rw,noatime ${DISK}1 /mnt/boot/efi/
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/var/log

# Install base system
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" base-system btrfs-progs grub-x86_64-efi grub-btrfs grub-btrfs-runit NetworkManager bash-completion vim 
for dir in sys dev proc; do mount --rbind /$dir /mnt/$dir; mount --make-rslave /mnt/$dir; done
cp -L /etc/resolv.conf /mnt/etc/

# Set hostname, timezone and locales
echo morpheus > /mnt/etc/hostname
chroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/default/libc-locales
XBPS_ARCH=$ARCH xbps-reconfigure -r /mnt -f glibc-locales

# Set root password
echo "-> Set password for root"
passwd root -R /mnt

# Create user and groups, and set password
groupadd -R /mnt socklog
groupadd -R /mnt libvirt
groupadd -R /mnt docker
groupadd -R /mnt bluetooth
useradd -R /mnt -mG wheel,input,kvm,socklog,libvirt,docker,audio,video,network,bluetooth vasco
echo "-> Set password for vasco"
passwd vasco -R /mnt

# Set ownership and permissions, and enable sudo foe wheel group
chown root:root /mnt
chmod 755 /mnt
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/10-wheel

# Write fstab
export BOOT_UUID=$(blkid -s UUID -o value ${DISK}1)
export ROOT_UUID=$(blkid -s UUID -o value ${DISK}2)

cat <<EOFSTAB >> /mnt/etc/fstab
UUID=$BOOT_UUID /boot/efi   vfat    defaults                        0 2
UUID=$ROOT_UUID /           btrfs   $BTRFS_OPT,subvol=@             0 0
UUID=$ROOT_UUID /home       btrfs   $BTRFS_OPT,subvol=@home         0 0
#UUID=$ROOT_UUID /.snapshots btrfs   $BTRFS_OPT,subvol=@snapshots    0 0
UUID=$ROOT_UUID /var/log    btrfs   $BTRFS_OPT,subvol=@/var/log     0 0
tmpfs           /tmp        tmpfs   defaults,noatime,mode=1777      0 0
EOFSTAB

# Enable zswap
echo "add_drivers+=\" lz4hc lz4hc_compress z3fold \"" >> /etc/dracut.conf.d/40-add_zswap_drivers.conf
sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ zswap.enabled=1 zswap.max_pool_percent=20 zswap.compressor=lz4hc zswap.zpool=z3fold&/" /mnt/etc/default/grub

# Install repositories
mkdir -p /mnt/etc/xbps.d
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree 

# Set repository mirrors
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf


# Install intel-ucode and nvidia drivers
XBPS_ARCH=$ARCH xbps-install -r /mnt -Syuv intel-ucode nvidia

# Configure nvidia, dracut and efibootmgr
cat <<EOMODPROBENVIDIACONF >> /mnt/etc/modprobe.d/nvidia.conf
blacklist nouveau
options nvidia-drm modeset=1
options nvidia NVreg_UsePageAttributeTable=1
EOMODPROBENVIDIACONF
cat <<EODRACUTCONF >> /mnt/etc/dracut.conf.d/options.conf
hostonly=yes
EODRACUTCONF

# Some nvidia fixes
mkdir -pv /mnt/udev/rules.d
chroot /mnt ln -s /dev/null /etc/udev/rules.d/61-gdm.rules

# Install extra packages
XBPS_ARCH=$ARCH xbps-install -r /mnt -Syuv gnome bluez pipewire gnome

# Install Flatpak
XBPS_ARCH=$ARCH xbps-install -r /mnt -Syuv flatpak

# Generate chroot script
cat << EOCHROOT > /mnt/chroot.sh
#!/usr/bin/bash
mount -t efivarfs efivarfs /sys/firmware/efi/efivars
grub-install --target=x86_64-efi --boot-directory=/boot --efi-directory=/boot/efi --bootloader-id="Void" --recheck
dracut --regenerate-all --force
update-grub
xbps-reconfigure -fa
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
EOCHROOT

# Run chroot script
chroot /mnt bash /chroot.sh

# Cleanup
rm /mnt/chroot.sh

# Install services
for service in elogind NetworkManager socklog-unix nanoklogd dbus avahi-daemon bluetoothd gdm; do
  chroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done

# Done
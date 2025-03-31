#!/usr/bin/bash
exec > >(tee -ia install.log)

# Global variables
BOOT_DISK=/dev/vda
POOL_DISK=/dev/vda
BOOT_PART=1
POOL_PART=2
KEYMAP=us-acentos
TIME_ZONE=Europe/Lisbon
ARCH=x86_64
REPO=https://repo-default.voidlinux.org
USER_NAME=vasco
HOST_NAME=morpheus
ZRAM_COMPRESSOR=zstd    # zram compression algorithm (see https://github.com/atweiden/zramen/blob/master/zramen or check `man zramctl`)
ZRAM_INIT_SIZE_PCT=25   # initial zram size as a percentage of total RAM
ZRAM_MAX_SIZE_MB=8192   # maximum zram size in MB

# Set boot and pool devices
if [[ $BOOT_DISK == *"nvme"* ]]; then
  BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"
else
  BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
fi
if [[ $POOL_DISK == *"nvme"* ]]; then
  POOL_DEVICE="${POOL_DISK}p${POOL_PART}"
else
  POOL_DEVICE="${POOL_DISK}${POOL_PART}"
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
sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"
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

# Install base system
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" base-system

# Set hostname, timezone, locales and keymap
echo $HOST_NAME > /mnt/etc/hostname
xchroot /mnt ln -sf /usr/share/zoneinfo/$TIME_ZONE /etc/localtime
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/default/libc-locales
sed -i "/#KEYMAP=/s/.*/KEYMAP=\"$KEYMAP\"/" /mnt/etc/rc.conf

# Copy DNS configuration and hostid
cp /etc/resolv.conf /mnt/etc/
cp /etc/hostid /mnt/etc/

# Set root password
echo "-> Set password for root"
while true; do passwd root -R /mnt && break; done

# Create user and groups, and set password
groupadd -R /mnt socklog
groupadd -R /mnt libvirt
groupadd -R /mnt docker
groupadd -R /mnt bluetooth
groupadd -R /mnt lpadmin
useradd -R /mnt -mG wheel,input,kvm,socklog,libvirt,docker,audio,video,network,bluetooth,lpadmin $USER_NAME
echo "-> Set password for $USER_NAME"
while true; do passwd $USER_NAME -R /mnt && break; done

# Set ownership and permissions, and enable sudo for wheel group
chown root:root /mnt
chmod 755 /mnt
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/wheel
echo "%wheel ALL= (ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /sbin/halt" >> /mnt/etc/sudoers.d/wheel # allow shutdown, reboot and halt without password
echo "Defaults timestamp_timeout=60" >> /mnt/etc/sudoers.d/wheel    # require password only every 60 minutes (default is 5)

# Configure zram swap
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt zramen
sed -i "s/.*ZRAM_COMP_ALGORITHM.*/export ZRAM_COMP_ALGORITHM=$ZRAM_COMPRESSOR/g" /mnt/etc/sv/zramen/conf
sed -i "s/.*ZRAM_SIZE.*/export ZRAM_SIZE=$ZRAM_INIT_SIZE_PCT/g" /mnt/etc/sv/zramen/conf
sed -i "s/.*ZRAM_MAX_SIZE.*/export ZRAM_MAX_SIZE=$ZRAM_MAX_SIZE_MB/g" /mnt/etc/sv/zramen/conf
echo "add_drivers+=\" zram \"" >> /mnt/etc/dracut.conf.d/drivers.conf

# Install repositories
mkdir -p /mnt/etc/xbps.d
XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO/current" void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree 

# Set repository mirrors
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org|$REPO|g" /mnt/etc/xbps.d/*-repository-*.conf

# Install intel and nvidia drivers
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy intel-ucode linux-firmware-intel vulkan-loader mesa-vulkan-intel intel-video-accel mesa-dri nvidia

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
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy \
  NetworkManager apparmor cronie xtools psmisc gpm socklog-void runit-iptables polkit \
  bluez pipewire wireplumber dbus avahi nss-mdns \
  gnome gnome-software firefox libreoffice virt-manager \
  xdg-user-dirs xdg-user-dirs-gtk xdg-utils xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
  cups foomatic-db foomatic-db-nonfree \
  dejavu-fonts-ttf xorg-fonts noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji nerd-fonts \
  restic autorestic nix \
  bash-completion vim git

# Configure pipewire
mkdir -p /mnt/etc/pipewire/pipewire.conf.d
xchroot /mnt ln -s /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
xchroot /mnt ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
xchroot /mnt ln -s /usr/share/applications/pipewire.desktop /etc/xdg/autostart/

# Configure gpm (console mouse)
mkdir -p /mnt/etc/conf.d
echo "GPM_ARGS=\"-m /dev/input/mice -t imps2\"" > /mnt/etc/conf.d/gpm

# Configure flatpak
XBPS_ARCH=$ARCH xbps-install -r /mnt -Sy flatpak
xchroot /mnt flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Set up XBPS-SRC
git clone https://github.com/void-linux/void-packages.git /mnt/home/$USER_NAME/void-packages
xchroot /mnt chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/void-packages
xchroot /mnt su - $USER_NAME -c "cd void-packages && ./xbps-src binary-bootstrap"
echo XBPS_ALLOW_RESTRICTED=yes >> /mnt/etc/conf

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
  CommandLine: quiet loglevel=0
EOZFSBMCFG

xchroot /mnt generate-zbm  # generate ZFSBootMenu image

# Enforce AppArmor
sed -i "/APPARMOR=/s/.*/APPARMOR=enforce/" /mnt/etc/default/apparmor
sed -i "/#write-cache/s/^#//" /mnt/etc/apparmor/parser.conf
sed -i "/#show_notifications/s/^#//" /mnt/etc/apparmor/notify.conf
xchroot /mnt zfs set org.zfsbootmenu:commandline="apparmor=1 security=apparmor" zroot/ROOT/${ID}

# Create EFI boot entries
xchroot /mnt efibootmgr --create --disk "$BOOT_DISK" --part "$BOOT_PART" \
  --label "ZFSBootMenu (Backup)" \
  --loader '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

xchroot /mnt efibootmgr --create --disk "$BOOT_DISK" --part "$BOOT_PART" \
  --label "ZFSBootMenu" \
  --loader '\EFI\ZBM\VMLINUZ.EFI'

# Install services
for service in elogind NetworkManager socklog-unix nanoklogd dbus avahi-daemon bluetoothd gdm cupsd saned zramen crond gpm power-profiles-daemon iptables ip6tables nix-daemon; do
  xchroot /mnt ln -sfv /etc/sv/$service /etc/runit/runsvdir/default
done

# Change vm.swappiness
mkdir -p /mnt/etc/sysctl.conf.d
echo "vm.swappiness = 10" >> /mnt/etc/sysctl.conf.d/99-swappiness.conf

# Set up NIX
mkdir -p /mnt/home/$USER_NAME/.config/nixpkgs
echo "{ allowUnfree = true; }" > /mnt/home/$USER_NAME/.config/nixpkgs/config.nix
xchroot /mnt sv up nix-daemon && su - $USER_NAME -c "nix-channel --add http://nixos.org/channels/nixpkgs-unstable && nix-channel --update"

# Setup .bash_profile
cat << EOBSHPROFILE >> /mnt/$USER_NAME/.bash_profile
# my shell aliases
alias ll='ls -lash'
alias xin='sudo xbps-install'
alias xq='xbps-query -Rs'
alias xr='sudo xbps-remove'
alias xro='sudo xbps-remove -o'

# show nix applications on the desktop environment
if [ -n \${XDG_SESSION_ID} ];then
    if [ -d ~/.nix-profile ];then
        for x in \$(find ~/.nix-profile/share/applications/*.desktop);do
            MY_XDG_DIRS=\$(dirname \$(dirname \$(readlink -f \$x))):\${MY_XDG_DIRS}
        done
        export XDG_DATA_DIRS=\${MY_XDG_DIRS}:\${XDG_DATA_DIRS}
    fi
fi
EOBSHPROFILE

# Reconfigure all packages
xchroot /mnt xbps-reconfigure -fa

# Unmount all filesystems
umount -n -R /mnt

# Export zpool and prepare for reboot
zpool export zroot
# void-install-script

This script performs automated Void Linux on a ZFS filesystem.

Features:
    - UEFI boot with `ZFSBootMenu`
    - ZFS root filesystem (WIPES ALL DATA WITHOUT PROMPTING)
    - `zram` swap space
    - `NetworkManager` and `elogind`
    - Proprietary NVIDIA drivers
    - Complete GNOME desktop environment
    - Flatpak support
    - AppArmor enforced
    - `xbps-src`
    - ...

Steps:
    1. Boot from a `hrmpf` rescue image (see https://github.com/leahneukirchen/hrmpf)
    2. Get the script with `wget https://raw.githubusercontent.com/vascosantos/void-install-script/main/install.sh`
    3. Update global variables in the beginning of the script: `vim install.sh`
    4. Run it with `bash install.sh`

It will only stop for user input for:
    1. Accepting the repository SSH key imports
    2. Setting root password
    3. Setting regular user password

Tested on a desktop PC using a wired Ethernet connection, Intel CPU (i7-12900K) and Nvidia GPU (GTX 1650 SUPER). 

PLEASE HANDLE WITH CARE AS ALL CONTENTS ON THE SELECTED DISK WILL BE LOST.
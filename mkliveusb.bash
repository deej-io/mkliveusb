#!/bin/bash

# This script will install an ubuntu ISO onto a usb stick with 1GB persisence file

set -e

function check_sudo() {
	if [ "$EUID" -ne 0 ]; then
		echo "Script needs to be run as root"
		exit
	fi
}

function check_installed() {
	for cmd in "$@"; do
		if [[ ! -x $(command -v $cmd) ]]; then
			local uninstalled="$uninstalled $cmd"
		fi
	done

	if [[ ! -z "$uninstalled" ]]; then
		echo These required packages are not installed: $uninstalled
		exit
	fi
}

DEVICE="$1"
IMAGE="$2"

check_sudo
check_installed parted syslinux mtools mkfs.vfat mkfs.ext4

if [[ -z "$DEVICE" || -z $IMAGE ]]; then
	echo "USAGE: $0 /dev/sdX path/to/image.iso"
	exit 1
fi

echo "Partitioning device"
parted $DEVICE mklabel msdos 2> /dev/null
parted $DEVICE mkpart primary 0% 100% 2> /dev/null
echo "Making device bootable"
parted $DEVICE set 1 boot on 2> /dev/null

PARTITION="${DEVICE}1"

echo "Formatting partition"
mkfs.vfat -F 32 $PARTITION

echo "Mounting partition and iso"
mkdir -p /mnt/usb
mkdir -p /mnt/iso

mount $PARTITION /mnt/usb
mount -o loop "$IMAGE" /mnt/iso

echo "Copying contents of ISO to device..."
# mute stderr and return true as cannot copy symlinks
cp -a /mnt/iso/. /mnt/usb > /dev/null 2>&1 || true

echo "Preparing for syslinux install"
mv /mnt/usb/isolinux /mnt/usb/syslinux
mv /mnt/usb/syslinux/isolinux.cfg /mnt/usb/syslinux/syslinux.cfg

echo "Creating persistence file"
dd if=/dev/zero of=/mnt/usb/casper-rw bs=1M count=1024
echo "Adding persistent flag to grub"
sed -e 's/boot=casper/\0 persistent/g' -i /mnt/usb/boot/grub/grub.cfg

echo "Syncing filesystems."
sync &
PID="$!"
while kill -0 $PID >/dev/null 2>&1; do
	printf "$(echo $(grep -e Dirty: -e Writeback: /proc/meminfo))\r\033[K"
	sleep 1
done;
echo

echo "Creating ext4 filesystem in persistence file"
mkfs.ext4 -L casper-rw /mnt/usb/casper-rw

echo "Installing syslinux"
syslinux -s $PARTITION

echo "Unmounting disks"
umount /mnt/iso
umount /mnt/usb

echo "done!"

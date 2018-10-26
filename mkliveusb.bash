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

function format_and_install() {
    local device=${1} 
    local image=${2}

    echo "Partitioning device"
    parted $device mklabel msdos
    parted $device mkpart primary 0% 100% 2> /dev/null
    echo "Making device bootable"
    parted $device set 1 boot on 2> /dev/null

    local partition="${device}1"

    echo "Formatting partition"
    mkfs.vfat -F 32 $partition

    echo "Mounting partition and iso"
    mkdir -p /mnt/usb
    mkdir -p /mnt/iso

    mount $partition /mnt/usb
    mount -o loop "$image" /mnt/iso

    echo "Copying contents of ISO to device"
    # mute stderr and return true as cannot copy symlinks
    cp -a /mnt/iso/. /mnt/usb > /dev/null 2>&1 || true

    echo "Preparing for syslinux install"
    mv /mnt/usb/isolinux /mnt/usb/syslinux
    mv /mnt/usb/syslinux/isolinux.cfg /mnt/usb/syslinux/syslinux.cfg

    echo "Creating persistence file"
    dd if=/dev/zero of=/mnt/usb/casper-rw bs=10M count=205
    echo "Adding persistent flag to grub"
    sed -e 's/boot=casper/\0 persistent/g' -i /mnt/usb/boot/grub/grub.cfg
    echo "\"Fix\" acpi-related hang on shutdown"
    sed -e 's/splash/acpi=force/g' -i /mnt/usb/boot/grub/grub.cfg

    echo "Syncing cached writes to device"
    sync &
    PID="$!"
    while kill -0 $PID >/dev/null 2>&1; do
            printf "$(echo $(grep -e Dirty: -e Writeback: /proc/meminfo))\033[K\r"
            sleep 1
    done;
    echo

    echo "Creating ext4 filesystem in persistence file"
    mkfs.ext4 -L casper-rw /mnt/usb/casper-rw

    echo "Installing syslinux"
    syslinux -s $partition

    echo "Installing grub for legacy BIOSs"
    grub-install --target=i386-pc --recheck --boot-directory=/mnt/usb/boot $device

    echo "Unmounting disks"
    umount /mnt/iso
    umount /mnt/usb
}

function download_image() {
    local iso_url=${1}
    echo "Downloading image file from ${iso_url} to ${DOWNLOAD_IMAGE_PATH}"
    curl -L -o ${DOWNLOAD_IMAGE_PATH} ${iso_url}
    # Make ISO accessible for any user so it can be easily removed later
    chmod 777 ${DOWNLOAD_IMAGE_PATH}
}

DEVICE="$1"
IMAGE="$2"
DOWNLOAD_IMAGE_PATH="/tmp/mkliveusb.iso"
ISO_URL="https://s3-eu-west-1.amazonaws.com/codeupleeds-beta/ubuntu-18.04.1-desktop-amd64.iso"

if [[ -z "$DEVICE" ]]; then
    echo "USAGE (root required): $0 /dev/sdX [-f <local_image_path>]"
    exit 1
fi

check_sudo
check_installed parted syslinux mtools mkfs.vfat mkfs.ext4 curl

while getopts ":f" OPTION;
do
    case ${OPTION} in
        f)  DEVICE="${2}"
            format_and_install ${DEVICE} ${OPTARG};;
        \?) echo "Invalid flags passed";;
    esac
done

if [[ ! -f ${DOWNLOAD_IMAGE_PATH} ]]; then
    download_image ${ISO_URL}
fi

format_and_install ${DEVICE} ${IMAGE}

if [[ -f ${DOWNLOAD_IMAGE_PATH} ]]; then
    echo "Deleting downloaded image file"
    rm ${DOWNLOAD_IMAGE_PATH}
fi

echo "done!"

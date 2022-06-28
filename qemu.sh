#!/usr/bin/env bash

help_text () {
	while IFS= read -r line; do
		printf "%s\n" "$line"
	done <<-EOF

	Usage:
	 ${0##*/} [-h | --help] [--video=<video_format>] [--hda=<hard_disk_image.qcow2>] [-cdrom=<iso_image>]

	Options:
	These options are supposed to be used only once during first run. Further configuration can be done by modifing qemu.conf

	 --video Set the format for video output. 
 		video_formats: qxl(spice),virtio,igpu
		NOTE: Refer to https://wiki.archlinux.org/title/Intel_GVT-g before using iGPU option

	 --hda 	 Specify hard disk image

	 --cdrom Specify iso file

	 -h,	 Show this text message and exit
	 --help
	EOF
}

VIDEO="VIRTIO"
CWD="$PWD"

for i in "$@"; do
  case $i in
    --video=*)
	    VIDEO="$(echo ${i#*=} | tr '[:lower:]' '[:upper:]')"
	    shift
	    ;;
    --hda=*)
	    HDA="-drive file=${i#*=},if=virtio,media=disk"
	    shift
	    ;;
    --cdrom=*)
	    CDROM="-drive file=${i#*=},if=virtio,media=cdrom"
	    shift
	    ;;
    -h|--help)
	    help_text
	    exit 0
	    ;;
    -*|--*)
	    echo "Unknown option $i"
	    help_text
	    exit 1
	    ;;
    *)
	    ;;
  esac
done


# ======================================================================================================================================================================

# Store env vars in a file
generate_config(){
	echo -e "==> No qemu.conf file found.\nCreating a default config..."
	
	CPUS=$(	  lscpu | tr -d ' ' | grep 'CPU(s)'    | head -n1 | cut -d':' -f2)
	SOCKETS=$(lscpu | tr -d ' ' | grep 'Socket(s)' | head -n1 | cut -d':' -f2)
	CORES=$(  lscpu | tr -d ' ' | grep 'Core(s)'   | head -n1 | cut -d':' -f2)
	THREADS=$(lscpu | tr -d ' ' | grep 'Thread(s)' | head -n1 | cut -d':' -f2)
	
	cat > ./qemu.conf << EOF
#!/usr/bin/env bash

IGPU="$IGPU"
CWD="$CWD"
GVT_PCI="0000:00:02.0"
GVT_GUID="$(uuidgen)"
MDEV_TYPE="i915-GVTg_V5_4"

VIRTIO_OPTS="-device virtio-vga-gl -display gtk,gl=on"
QXL_OPTS="-vga qxl -device virtio-serial-pci -spice port=5930,disable-ticketing=on -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 -chardev spicevmc,id=spicechannel0,name=vdagent"
IGPU_OPTS="-device vfio-pci,sysfsdev=/sys/bus/mdev/devices/\$GVT_GUID,display=on,x-igd-opregion=on,ramfb=on,driver=vfio-pci-nohotplug -vga none -display gtk,gl=on"

BOOT="-boot menu=on,order=dc $HDA $CDROM"
CPU="-cpu host -smp $CPUS,sockets=$SOCKETS,cores=$CORES,threads=$THREADS,maxcpus=$CPUS"
MEM="-m $(($(lsmem --bytes --summary | tr -d ' ' | grep online | cut -d':' -f2)/1024/1024/2))" # Using half of total RAM
AUDIO="" # Need help
VIDEO="\$${VIDEO}_OPTS"

QEMU_OPTS="-enable-kvm \$BOOT \$CPU \$MEM \$AUDIO \$VIDEO"
OTHER_OPTS=""
EOF

	echo -n "==> Created a default config. Review it to make changes [Y/n]: "
	read choice
	choice=${choice:-y}

	if [[ -z $EDITOR ]]; then
		echo "\$EDITOR not set"
		exit 1
	fi

	[[ "$choice" == *[yY]* ]] && $EDITOR ./qemu.conf || echo -e "\nWarning! Launching qemu/kvm with default options...\n"

}

run_vm(){
	cd $CWD
	
	source ./qemu.conf

	[[ "$VIDEO" == "$IGPU_OPTS" ]] && echo "$GVT_GUID" | sudo -- tee /sys/bus/pci/devices/$GVT_PCI/mdev_supported_types/$MDEV_TYPE/create > /dev/null;SUDO=sudo || echo -n

	$SUDO qemu-system-x86_64 $QEMU_OPTS $OTHER_OPTS 2> qemu.log

	[[ "$VIDEO" == "$IGPU_OPTS" ]] && echo 1 | sudo -- tee /sys/bus/pci/devices/${GVT_PCI}/${GVT_GUID}/remove > /dev/null || echo -n
}


# ========================================================================================================================================================================

# ##########
# ## MAIN ##
# ##########

if [[ -f "$CWD/qemu.log" ]]; then
	rm $CWD/qemu.log
fi

if [[ ! -e "$CWD/qemu.conf" ]]; then
	generate_config
fi
run_vm

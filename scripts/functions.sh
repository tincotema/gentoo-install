#!/bin/bash

source "$GENTOO_BOOTSTRAP_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

check_has_program() {
	type "$1" &>/dev/null \
		|| die "Missing program: '$1'"
}

sync_time() {
	einfo "Syncing time"
	ntpd -g -q >/dev/null \
		|| die "Could not sync time with remote server"

	einfo "Current date: $(LANG=C date)"
	einfo "Writing time to hardware clock"
	hwclock --systohc --utc >/dev/null \
		|| die "Could not save time to hardware clock"
}

prepare_installation_environment() {
	einfo "Preparing installation environment"

	check_has_program gpg
	check_has_program hwclock
	check_has_program lsblk
	check_has_program ntpd
	check_has_program partprobe
	check_has_program python3
	check_has_program rhash
	check_has_program sgdisk
	check_has_program uuidgen
	check_has_program wget

	sync_time
}

partition_device_print_config_summary() {
	echo "-------- Partition configuration --------"
	echo "Device: [1;33m$PARTITION_DEVICE[m"
	elog "Existing partition table:"
	lsblk -n "$PARTITION_DEVICE" \
		|| die "Error in lsblk"
	elog "New partition table:"
	echo "[1;33m$PARTITION_DEVICE[m"
	echo "├─efi   size=[1;32m$PARTITION_EFI_SIZE[m"
	if [[ "$ENABLE_SWAP" == true ]]; then
	echo "├─swap  size=[1;32m$PARTITION_SWAP_SIZE[m"
	fi
	echo "└─linux size=[1;32m[remaining][m"
	if [[ "$ENABLE_SWAP" != true ]]; then
	echo "swap: [1;31mdisabled[m"
	fi
	echo
}

partition_device() {
	[[ "$ENABLE_PARTITIONING" == true ]] \
		|| return 0

	einfo "Preparing partitioning of device '$PARTITION_DEVICE'"

	[[ -b "$PARTITION_DEVICE" ]] \
		|| die "Selected device '$PARTITION_DEVICE' is not a block device"

	partition_device_print_config_summary
	ask "Do you really want to apply this partitioning?" \
		|| die "For manual partitioning formatting please set ENABLE_PARTITIONING=false in config.sh"
	countdown "Partitioning in " 5

	einfo "Partitioning device '$PARTITION_DEVICE'"

	# Delete any existing partition table
	sgdisk -Z "$PARTITION_DEVICE" >/dev/null \
		|| die "Could not delete existing partition table"

	# Create efi/boot partition
	sgdisk -n "0:0:+$PARTITION_EFI_SIZE" -t 0:ef00 -c 0:"efi" -u 0:"$PARTITION_UUID_EFI" "$PARTITION_DEVICE" >/dev/null \
		|| die "Could not create efi partition"

	# Create swap partition
	if [[ "$ENABLE_SWAP" == true ]]; then
		sgdisk -n "0:0:+$PARTITION_SWAP_SIZE" -t 0:8200 -c 0:"swap" -u 0:"$PARTITION_UUID_SWAP" "$PARTITION_DEVICE" >/dev/null \
			|| die "Could not create swap partition"
	fi

	# Create system partition
	sgdisk -n 0:0:0 -t 0:8300 -c 0:"linux" -u 0:"$PARTITION_UUID_LINUX" "$PARTITION_DEVICE" >/dev/null \
		|| die "Could not create linux partition"

	# Print partition table
	einfo "Applied partition table:"
	sgdisk -p "$PARTITION_DEVICE" \
		|| die "Could not print partition table"

	# Inform kernel of partition table changes
	partprobe "$PARTITION_DEVICE" \
		|| die "Could not probe partitions"
}

format_partitions() {
	[[ "$ENABLE_FORMATTING" == true ]] \
		|| return 0

	if [[ "$ENABLE_PARTITIONING" != true ]]; then
		einfo "Preparing to format the following partitions:"

		blkid -t PARTUUID="$PARTITION_UUID_EFI" \
			|| die "Error while listing efi partition"
		if [[ "$ENABLE_SWAP" == true ]]; then
			blkid -t PARTUUID="$PARTITION_UUID_SWAP" \
				|| die "Error while listing swap partition"
		fi
		blkid -t PARTUUID="$PARTITION_UUID_LINUX" \
			|| die "Error while listing linux partition"

		ask "Do you really want to format these partitions?" \
			|| die "For manual formatting please set ENABLE_FORMATTING=false in config.sh"
		countdown "Formatting in " 5
	fi

	einfo "Formatting partitions"

	local dev
	dev="$(get_device_by_partuuid "$PARTITION_UUID_EFI")" \
		|| die "Could not resolve partition UUID '$PARTITION_UUID_EFI'"
	einfo "  $dev (efi)"
	mkfs.fat -F 32 -n "efi" "$dev" \
		|| die "Could not format EFI partition"

	if [[ "$ENABLE_SWAP" == true ]]; then
		dev="$(get_device_by_partuuid "$PARTITION_UUID_SWAP")" \
			|| die "Could not resolve partition UUID '$PARTITION_UUID_SWAP'"
		einfo "  $dev (swap)"
		mkswap -L "swap" "$dev" \
			|| die "Could not create swap"
	fi

	dev="$(get_device_by_partuuid "$PARTITION_UUID_LINUX")" \
		|| die "Could not resolve partition UUID '$PARTITION_UUID_LINUX'"
	einfo "  $dev (linux)"
	mkfs.ext4 -L "linux" "$dev" \
		|| die "Could not create ext4 filesystem"
}

mount_root() {
	# Skip if root is already mounted
	mountpoint -q -- "$ROOT_MOUNTPOINT" \
		&& return

	# Mount root device
	einfo "Mounting root device"
	mkdir -p "$ROOT_MOUNTPOINT" \
		|| die "Could not create mountpoint directory $ROOT_MOUNTPOINT"
	local dev
	dev="$(get_device_by_partuuid "$PARTITION_UUID_LINUX")" \
		|| die "Could not resolve partition UUID '$PARTITION_UUID_LINUX'"
	mount "$dev" "$ROOT_MOUNTPOINT" \
		|| die "Could not mount root device '$dev'"
}

bind_bootstrap_dir() {
	# Bind the bootstrap dir to a location in /tmp,
	# so it can be accessed from within the chroot
	mountpoint -q -- "$GENTOO_BOOTSTRAP_BIND" \
		&& return

	# Mount root device
	einfo "Bind mounting bootstrap directory"
	mkdir -p "$GENTOO_BOOTSTRAP_BIND" \
		|| die "Could not create mountpoint directory '$GENTOO_BOOTSTRAP_BIND'"
	mount --bind "$GENTOO_BOOTSTRAP_DIR" "$GENTOO_BOOTSTRAP_BIND" \
		|| die "Could not bind mount '$GENTOO_BOOTSTRAP_DIR' to '$GENTOO_BOOTSTRAP_BIND'"
}

download_stage3() {
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	local STAGE3_RELEASES="$GENTOO_MIRROR/releases/amd64/autobuilds/current-$STAGE3_BASENAME/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | head -1)" \
		|| die "Could not parse list of tarballs"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"

	# Download file if not already downloaded
	if [[ -e "$CURRENT_STAGE3" ]] ; then
		einfo "$STAGE3_BASENAME tarball already exists"
	else
		einfo "Downloading $STAGE3_BASENAME tarball"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS.asc" "${CURRENT_STAGE3}.DIGESTS.asc"
	fi

	# Import gentoo keys
	einfo "Importing gentoo gpg key"
	local GENTOO_GPG_KEY="$TMP_DIR/gentoo-keys.gpg"
	download "https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng" "$GENTOO_GPG_KEY" \
		|| die "Could not retrieve gentoo gpg key"
	gpg --import < "$GENTOO_GPG_KEY" \
		|| die "Could not import gentoo gpg key"

	# Verify DIGESTS signature
	einfo "Verifying DIGEST.asc signature"
	gpg --verify "${CURRENT_STAGE3}.DIGESTS.asc" \
		|| die "Signature of '${CURRENT_STAGE3}.DIGESTS.asc' invalid!"

	# Check hashes
	einfo "Verifying tarball integrity"
	rhash -P --check <(grep -B 1 'tar.xz$' "${CURRENT_STAGE3}.DIGESTS.asc") \
		|| die "Checksum mismatch!"
}

extract_stage3() {
	mount_root

	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 is not set"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 file does not exist"

	# Go to root directory
	cd "$ROOT_MOUNTPOINT" \
		|| die "Could not move to '$ROOT_MOUNTPOINT'"
	# Ensure the directory is empty
	find . -mindepth 1 -maxdepth 1 -not -name 'lost+found' \
		| grep -q . \
		&& die "root directory '$ROOT_MOUNTPOINT' is not empty"

	# Extract tarball
	einfo "Extracting stage3 tarball"
	tar xpf "$TMP_DIR/$CURRENT_STAGE3" --xattrs --numeric-owner \
		|| die "Error while extracting tarball"
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"
}

gentoo_chroot() {
	[[ $# -gt 0 ]] || die "Missing command argument"

	mount_root
	bind_bootstrap_dir

	# Copy resolv.conf
	einfo "Preparing chroot environment"
	cp /etc/resolv.conf "$ROOT_MOUNTPOINT/etc/resolv.conf" \
		|| die "Could not copy resolv.conf"

	# Mount virtual filesystems
	einfo "Mounting virtual filesystems"
	(
		mountpoint -q -- "$ROOT_MOUNTPOINT/proc" || mount -t proc /proc "$ROOT_MOUNTPOINT/proc" || exit 1
		mountpoint -q -- "$ROOT_MOUNTPOINT/tmp"  || mount --rbind /tmp  "$ROOT_MOUNTPOINT/tmp"  || exit 1
		mountpoint -q -- "$ROOT_MOUNTPOINT/sys"  || mount --rbind /sys  "$ROOT_MOUNTPOINT/sys"  || exit 1
		mountpoint -q -- "$ROOT_MOUNTPOINT/sys"  || mount --make-rslave "$ROOT_MOUNTPOINT/sys"  || exit 1
		mountpoint -q -- "$ROOT_MOUNTPOINT/dev"  || mount --rbind /dev  "$ROOT_MOUNTPOINT/dev"  || exit 1
		mountpoint -q -- "$ROOT_MOUNTPOINT/dev"  || mount --make-rslave "$ROOT_MOUNTPOINT/dev"  || exit 1
	) || die "Could not mount virtual filesystems"

	# Execute command
	einfo "Chrooting..."
	EXECUTED_IN_CHROOT=true \
		TMP_DIR=$TMP_DIR \
		exec chroot "$ROOT_MOUNTPOINT" "$GENTOO_BOOTSTRAP_BIND/scripts/main_chroot.sh" "$@" \
		|| die "Failed to chroot into '$ROOT_MOUNTPOINT'"
}
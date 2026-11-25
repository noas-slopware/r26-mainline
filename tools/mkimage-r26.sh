#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# mkimage-r26.sh: build the SD card image for the Gustard R26: Alpine Linux (armv7) with the
# packages of this branch, one ext4 partition that the stock U-Boot boots from.
#
#   tools/mkimage-r26.sh <out dir> [<tag>]
#
# <tag> defaults to today (YYYY.MM.DD). Out:
#   alpine-gustard-r26-<tag>.img.zst   the card image: MBR, partition 1 from sector 2048, ext4
#                                      (label alpine) with /GustardCore and /00 in its root
#   .sha256, .sha512, sha256sums
#
# The packages come from the published repository (GitHub Pages) unless R26_LOCAL_REPO points
# at an abuild REPODEST (tools/abuild-docker.sh): then the files are named NOT-FOR-RELEASE-*,
# since the image's apk database would name packages the published repository does not have.
#
# What is in it: alpine-base, mdevd, OpenRC, BusyBox syslog in RAM, chrony with Alpine's pool,
# set up to write to the card as little as possible (noatime, commit=60, /tmp and /var/tmp in
# RAM, no swap, no chrony drift file),
# OpenSSH (keys only, no key installed), device-gustard-r26 (+ -repo), raat-endpoint. No
# accounts besides root, root has no password, no SSH host keys (sshd makes them on first boot),
# no Roon identity (raat-endpoint makes one on first start). tools/verify-image.sh checks that
# nothing of the build machine or of anyone's box is in it (R26_VERIFY_DENY: a private list of strings).
#
# Needs docker with armv7 emulation (qemu-user binfmt). The container runs --privileged for
# the /dev and /proc mounts the package scripts expect.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "$1")
tag=${2:-$(date -u +%Y.%m.%d)}
ver=${ALPINE_VERSION:-3.24}
site=${R26_SITE:-https://noas-slopware.github.io/r26-mainline}
key=r26-mainline-1cc0db58.rsa.pub
size_mib=${R26_IMAGE_MIB:-768}

name=alpine-gustard-r26-$tag
repo_args=(-e R26_REPO="$site/alpine/v$ver/gustard-r26")
if [ -n "${R26_LOCAL_REPO:-}" ]; then
	name=NOT-FOR-RELEASE-$name
	repo_args=(-v "$(realpath "$R26_LOCAL_REPO")/gustard-r26:/localrepo:ro" -e R26_REPO=/localrepo)
	[ -n "${R26_LOCAL_KEY:-}" ] && repo_args+=(-v "$(realpath "$R26_LOCAL_KEY"):/localkey.rsa.pub:ro")
fi
deny_args=()
[ -z "${R26_VERIFY_DENY:-}" ] || deny_args=(-v "$(realpath "$R26_VERIFY_DENY"):/deny:ro" -e R26_VERIFY_DENY=/deny)
mkdir -p "$out"
# one fixed work directory (literal paths only: they are also the only paths this script removes)
work=/var/tmp/r26-image-build
[ ! -e /var/tmp/r26-image-build ] || { echo "/var/tmp/r26-image-build exists: another build running?" >&2; exit 1; }
mkdir -p /var/tmp/r26-image-build
trap 'rm -rf /var/tmp/r26-image-build' EXIT

docker run --rm --privileged --platform linux/arm/v7 \
	-v "$here:/src:ro" -v "$work:/w" "${repo_args[@]}" "${deny_args[@]}" \
	-e VER="$ver" -e KEY="$key" -e SIZE_MIB="$size_mib" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	alpine:"$ver" sh -euc '
	apk -q add e2fsprogs sfdisk >/dev/null
	# the root-owned parts never outlive the container
	trap "umount /w/root/proc /w/root/dev 2>/dev/null; rm -rf /w/root /w/fs.ext4" EXIT
	R=/w/root
	mkdir -p $R/etc/apk/keys $R/dev $R/proc
	cp /src/device-gustard-r26/$KEY /etc/apk/keys/
	cp /src/device-gustard-r26/$KEY $R/etc/apk/keys/
	[ ! -f /localkey.rsa.pub ] || { cp /localkey.rsa.pub /etc/apk/keys/; cp /localkey.rsa.pub $R/etc/apk/keys/; }
	cat > $R/etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v$VER/main
https://dl-cdn.alpinelinux.org/alpine/v$VER/community
EOF
	mount -t devtmpfs dev $R/dev
	mount -t proc proc $R/proc
	apk --root $R --initdb --arch armv7 --no-cache -X "$R26_REPO" --update-cache add \
		alpine-base mdevd-openrc openssh-server chrony e2fsprogs tzdata \
		device-gustard-r26 device-gustard-r26-repo raat-endpoint raat-endpoint-openrc
	umount $R/proc $R/dev

	# --- system configuration
	echo gustard-r26 > $R/etc/hostname
	printf "127.0.0.1\tlocalhost gustard-r26\n::1\t\tlocalhost gustard-r26\n" > $R/etc/hosts
	ln -sfn /usr/share/zoneinfo/UTC $R/etc/localtime
	echo UTC > $R/etc/timezone
	# no password for root: "*" (never "!": sshd without PAM treats "!" as locked and refuses keys too)
	sed -i "s/^root:[^:]*:/root:*:/" $R/etc/shadow
	grep -q "^root:\*:" $R/etc/shadow
	mkdir -p -m 700 $R/root/.ssh
	cat > $R/etc/ssh/sshd_config.d/10-r26.conf <<EOF
# Key authentication only (this file is read before the main sshd_config, first value wins).
# Put your public key in /root/.ssh/authorized_keys on the card before the first boot.
PermitRootLogin prohibit-password
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF
	cat > $R/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
	hostname gustard-r26
EOF
	echo "SYSLOGD_OPTS=\"-t -C64\"" > $R/etc/conf.d/syslog
	cat > $R/etc/inittab <<EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF
	# --- as few writes to the card as possible: no atime updates, journal commits batched to
	# a minute, scratch space in RAM, syslog in RAM (above), no swap, no chrony drift file
	cat > $R/etc/fstab <<EOF
LABEL=alpine	/	ext4	rw,noatime,commit=60	0	1
tmpfs	/tmp	tmpfs	nosuid,nodev,mode=1777,size=32m	0	0
tmpfs	/var/tmp	tmpfs	nosuid,nodev,mode=1777,size=16m	0	0
EOF
	sed -i -e "/^driftfile /d" -e "/^ntsdumpdir /d" $R/etc/chrony/chrony.conf
	! grep -q -E "^(driftfile|ntsdumpdir|log) " $R/etc/chrony/chrony.conf
	sed -i "s/^#rc_cgroup_mode=\"unified\"$/rc_cgroup_mode=\"unified\"/" $R/etc/rc.conf
	grep -q "^rc_cgroup_mode=\"unified\"$" $R/etc/rc.conf
	: > $R/etc/resolv.conf
	rm -f $R/etc/machine-id

	# --- runlevels
	add() { lvl=$1; shift; for s in "$@"; do [ -e $R/etc/init.d/$s ]; ln -sfn /etc/init.d/$s $R/etc/runlevels/$lvl/$s; done; }
	add sysinit devfs dmesg cgroups mdevd mdevd-init hw-watchdog
	add boot osclock fsck root localmount bootmisc hostname sysctl syslog seedrng networking
	add default sshd chronyd raat-endpoint
	add shutdown killprocs savecache mount-ro
	for l in sysinit boot default shutdown; do echo "$l: $(ls $R/etc/runlevels/$l | tr "\n" " ")"; done

	# the kernel where U-Boot loads it (r26-boot-deploy ran in the trigger)
	[ -s $R/GustardCore ] && [ -s $R/00 ]
	cmp $R/GustardCore $R/boot/gustard-r26/zImage
	cmp $R/00 $R/boot/gustard-r26/gustard-r26.dtb

	/src/tools/verify-image.sh $R

	# --- file system and disk: conservative ext4 features, as the stock U-Boot (2022.07) reads it
	fs_mib=$((SIZE_MIB - 1))
	mkfs.ext4 -q -F -t ext4 -L alpine -I 256 -m 1 \
		-O none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize \
		-d $R /w/fs.ext4 ${fs_mib}M
	e2fsck -fn /w/fs.ext4
	truncate -s ${SIZE_MIB}M /w/disk.img
	echo "start=2048, type=83" | sfdisk -q --label dos /w/disk.img
	dd if=/w/fs.ext4 of=/w/disk.img bs=1M seek=1 conv=notrunc status=none
	sfdisk -l /w/disk.img
	du -sh $R
	chown "$HOST_UID:$HOST_GID" /w/disk.img
'
zstd -q -19 -T0 -f "$work/disk.img" -o "$out/$name.img.zst"
cd "$out"
sha256sum "$name.img.zst" > "$name.img.zst.sha256"
sha512sum "$name.img.zst" > "$name.img.zst.sha512"
sha256sum "$name.img.zst" >> sha256sums
sort -u -k2 -o sha256sums sha256sums
ls -l "$out"

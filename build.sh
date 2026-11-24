#!/bin/bash
# Build the R26 kernel: stable v7.3.6 + kernel/patches, LLVM, allnoconfig + fragments.
#   ./build.sh          production kernel (config/r26.config)
#   ./build.sh test     test kernel for the r26kexec loader (adds config/r26-test.config
#                       and the initramfs from initramfs/build.sh)
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$here/out/linux
obj=$here/out/build-${1:-prod}
if [ ! -d "$src/.git" ]; then
	git clone --depth 1 --branch v7.3.6 \
		https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$src"
	git -C "$src" -c user.name=r26 -c user.email=r26@localhost am -q "$here"/kernel/patches/*.patch
fi
mkdir -p "$obj"
cfg=$obj/merged.config
cp "$here/config/r26.config" "$cfg"
if [ "$1" = test ]; then
	cat "$here/config/r26-test.config" >> "$cfg"
	echo "CONFIG_INITRAMFS_SOURCE=\"$here/initramfs/out/initramfs.list\"" >> "$cfg"
fi
make -C "$src" -s O="$obj" ARCH=arm LLVM=1 KCONFIG_ALLCONFIG="$cfg" allnoconfig
while IFS= read -r l; do
	case "$l" in CONFIG_*=n|'#'*|'') ;; CONFIG_*) grep -qxF "$l" "$obj/.config" || echo "warning: $l did not stick";; esac
done < "$cfg"
make -C "$src" -j"$(nproc)" O="$obj" ARCH=arm LLVM=1 zImage sigmastar/mstar-infinity2m-ssd202d-gustard-r26.dtb
echo "zImage: $obj/arch/arm/boot/zImage"
echo "dtb:    $obj/arch/arm/boot/dts/sigmastar/mstar-infinity2m-ssd202d-gustard-r26.dtb"

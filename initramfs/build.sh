#!/bin/bash
# Build the test initramfs: static busybox + dropbear (Arm GNU 8.2 glibc), its NSS bits,
# a freshly generated dropbear host key and your SSH public key.
#   AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub ./initramfs/build.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$here/out; dl=$out/dl; mkdir -p "$dl" "$out/root"
tc=gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf
fetch() { [ -f "$dl/$2" ] || curl -sSfL -o "$dl/$2" "$1/$2"; echo "$3  $dl/$2" | sha256sum -c --quiet; }
fetch https://developer.arm.com/-/media/Files/downloads/gnu-a/8.2-2018.08 $tc.tar.xz \
	$(cat "$here/toolchain.sha256")
fetch https://busybox.net/downloads busybox-1.38.0.tar.bz2 34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2
fetch https://matt.ucc.asn.au/dropbear/releases dropbear-2026.94.tar.bz2 e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
[ -d "$out/$tc" ] || tar -C "$out" -xf "$dl/$tc.tar.xz"
export PATH=$out/$tc/bin:$PATH
if [ ! -x "$out/root/busybox" ]; then
	rm -rf "$out/busybox-1.38.0"; tar -C "$out" -xf "$dl/busybox-1.38.0.tar.bz2"
	( cd "$out/busybox-1.38.0" && make -s defconfig >/dev/null &&
	  sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config &&
	  make -s oldconfig </dev/null >/dev/null && make -s -j"$(nproc)" CROSS_COMPILE=arm-linux-gnueabihf- )
	cp "$out/busybox-1.38.0/busybox" "$out/root/busybox"
fi
if [ ! -x "$out/root/dropbearmulti" ]; then
	rm -rf "$out/dropbear-2026.94"; tar -C "$out" -xf "$dl/dropbear-2026.94.tar.bz2"
	( cd "$out/dropbear-2026.94" && ./configure -q --host=arm-linux-gnueabihf --enable-static --disable-zlib \
		--disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
		--disable-pututline --disable-pututxline && make -s -j"$(nproc)" PROGRAMS="dropbear dropbearkey" MULTI=1 STATIC=1 )
	arm-linux-gnueabihf-strip -o "$out/root/dropbearmulti" "$out/dropbear-2026.94/dropbearmulti"
fi
for l in ld-linux-armhf.so.3 libc.so.6 libnss_files.so.2; do
	cp -L "$out/$tc/arm-linux-gnueabihf/libc/lib/$l" "$out/root/$l"
	arm-linux-gnueabihf-strip --strip-debug "$out/root/$l"
done
[ -f "$out/root/dropbear_ed25519_host_key" ] ||
	qemu-arm "$out/root/dropbearmulti" dropbearkey -t ed25519 -f "$out/root/dropbear_ed25519_host_key"
cp "${AUTHORIZED_KEYS:?set AUTHORIZED_KEYS to your ssh public key}" "$out/root/authorized_keys"
cp "$here/init" "$out/root/init"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$out/root/passwd"; printf 'root:x:0:\n' > "$out/root/group"
printf 'passwd: files\ngroup: files\nshadow: files\n' > "$out/root/nsswitch.conf"; printf '/bin/sh\n' > "$out/root/shells"
sed "s|@ROOT@|$out/root|g" "$here/initramfs.list.in" > "$out/initramfs.list"
echo "initramfs list: $out/initramfs.list"

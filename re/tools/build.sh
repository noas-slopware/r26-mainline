#!/bin/bash
# Build the on-device RE tools (static armhf, Arm GNU 8.2 from initramfs/build.sh).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cc=$here/../../initramfs/out/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf/bin/arm-linux-gnueabihf-gcc
for t in riuread riuw1c spinand-dump; do
	"$cc" -O2 -Wall -Wextra -static -o "$here/$t/$t" "$here/$t/$t.c"
done

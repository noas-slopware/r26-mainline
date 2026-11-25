#!/bin/bash
# Build the on-device RE tools (static armhf). CC defaults to the Arm GNU 8.2 toolchain that
# tools/bringup/initramfs/build.sh on the senpai branch downloads, with senpai checked out next
# to this branch (git worktree) as ../senpai.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cc=${CC:-$here/../../../../senpai/tools/bringup/initramfs/out/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf/bin/arm-linux-gnueabihf-gcc}
for t in riuread riuw1c spinand-dump r26peek; do
	"$cc" -O2 -Wall -Wextra -static -o "$here/$t/$t" "$here/$t/$t.c"
done

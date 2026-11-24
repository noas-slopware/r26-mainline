#!/bin/bash
# Build r26kexec (static, Arm GNU 8.2 from initramfs/build.sh) and the flat trampoline.
set -e
here=$(cd "$(dirname "$0")" && pwd)
tc=$here/../initramfs/out/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf/bin
mkdir -p "$here/out"
clang --target=armv7a-none-eabi -march=armv7-a -c "$here/trampoline.S" -o "$here/out/trampoline.o"
# Link so the local bl calls get resolved (the assembler leaves them as relocations).
ld.lld -static -nostdlib -e tramp_start --image-base=0 -Ttext=0 -o "$here/out/trampoline.elf" "$here/out/trampoline.o"
llvm-objcopy -O binary "$here/out/trampoline.elf" "$here/out/trampoline.bin"
"$tc/arm-linux-gnueabihf-gcc" -O2 -Wall -Wextra -static -o "$here/out/r26kexec" "$here/r26kexec.c"
ls -l "$here/out/r26kexec" "$here/out/trampoline.bin"

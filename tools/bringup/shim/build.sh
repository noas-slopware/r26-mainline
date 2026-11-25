#!/bin/bash
# Build the flat shim binary. Assemble an image with mkshim.py, e.g.
#   ./mkshim.py out/shim.bin stock-GustardCore zImage r26.dtb GustardCore --mode 1
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/out"
clang --target=armv7a-none-eabi -march=armv7-a -c "$here/shim.S" -o "$here/out/shim.o"
# Link so the local bl calls get resolved (the assembler leaves them as relocations).
ld.lld -static -nostdlib -e _start --image-base=0 -Ttext=0 -o "$here/out/shim.elf" "$here/out/shim.o"
llvm-objcopy -O binary "$here/out/shim.elf" "$here/out/shim.bin"
ls -l "$here/out/shim.bin"

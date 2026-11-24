#!/usr/bin/env python3
"""Assemble the r26 boot shim image.

usage: mkshim.py <shim.bin> <stock-zImage> <main-zImage> <main.dtb> <out>
                 [--mode N] [--dtb-dest ADDR] [--wdt-seconds S]
                 [--wdt-base ADDR] [--pmpor ADDR] [--sim-choice N]
                 [--max-size N]

Layout: shim code (4 KiB aligned) | stock zImage | mainline zImage | DTB,
each payload starting on a 4 KiB boundary. Header words at 0x2c and
0x30..0x54 are filled in (see shim.S).
"""
import argparse
import struct


def align(b, n=4096):
    return b + b'\0' * (-len(b) % n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('shim'); ap.add_argument('stock'); ap.add_argument('main')
    ap.add_argument('dtb'); ap.add_argument('out')
    ap.add_argument('--mode', type=int, default=0)
    ap.add_argument('--dtb-dest', type=lambda x: int(x, 0), default=0x27000000)
    ap.add_argument('--wdt-seconds', type=int, default=300)
    ap.add_argument('--wdt-base', type=lambda x: int(x, 0), default=0x1f006000)
    ap.add_argument('--pmpor', type=lambda x: int(x, 0), default=0x1f000c04)
    ap.add_argument('--sim-choice', type=int, default=0)
    ap.add_argument('--max-size', type=lambda x: int(x, 0), default=0x800000)
    a = ap.parse_args()

    shim = bytearray(align(open(a.shim, 'rb').read()))
    stock = align(open(a.stock, 'rb').read())
    main_z = align(open(a.main, 'rb').read())
    dtb = open(a.dtb, 'rb').read()
    dtb_size = (len(dtb) + 3) & ~3
    dtb = dtb + b'\0' * (dtb_size - len(dtb))

    for name, z in (('stock', stock), ('main', main_z)):
        if struct.unpack_from('<I', z, 0x24)[0] != 0x016f2818:
            raise SystemExit(f'{name} is not a zImage')
    if struct.unpack_from('>I', dtb, 0)[0] != 0xd00dfeed:
        raise SystemExit('dtb is not a flattened device tree')
    if not 0 < a.wdt_seconds <= 300:
        raise SystemExit('wdt seconds must be 1..300')

    stock_off = len(shim)
    main_off = stock_off + len(stock)
    dtb_off = main_off + len(main_z)
    total = dtb_off + dtb_size

    # The stock U-Boot (2022.07-rc2+ for som2d01, built-in env) ext4loads
    # /GustardCore to 0x22000000 and then /00 to 0x22800000, so anything past
    # 8 MiB would be overwritten by the DTB load.
    if total > a.max_size:
        raise SystemExit(f'image is {total:#x} bytes, over the {a.max_size:#x} limit')
    struct.pack_into('<I', shim, 0x2c, total)
    struct.pack_into('<10I', shim, 0x30,
                     a.mode, stock_off, main_off, dtb_off, dtb_size, a.dtb_dest,
                     a.wdt_seconds * 12000000, a.wdt_base, a.pmpor, a.sim_choice)
    img = bytes(shim) + stock + main_z + dtb
    assert len(img) == total
    open(a.out, 'wb').write(img)
    print(f'{a.out}: {total} bytes (stock @{stock_off:#x}, main @{main_off:#x}, '
          f'dtb @{dtb_off:#x} -> {a.dtb_dest:#x}, mode {a.mode})')


if __name__ == '__main__':
    main()

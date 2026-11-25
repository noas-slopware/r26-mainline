#!/usr/bin/env python3
"""Name functions in a stripped Thumb-2 kernel Image using a symbolized vmlinux.

usage: fnmatch.py <vmlinux> <Image> <image-base-hex> <out.tsv>

For every FUNC symbol in vmlinux, build a masked halfword signature:
  - BL/BLX/B.W (32-bit branches): whole instruction masked
  - MOVW/MOVT: immediate masked
  - LDR literal (16-bit and 32-bit): the referenced pool word masked
Then find every position in Image where the signature matches.
Output: name, vmlinux addr, size, status (unique/multi/none), Image addr(s).
"""
import sys
from collections import defaultdict
from elftools.elf.elffile import ELFFile

MIN_SIZE = 16  # bytes; smaller functions are too ambiguous


def is32(hw):
    return (hw >> 11) in (0x1D, 0x1E, 0x1F)


def build_sig(code, start_addr):
    """Return list of (halfword or None) for the function bytes."""
    n = len(code) // 2
    hws = [code[2 * i] | (code[2 * i + 1] << 8) for i in range(n)]
    mask = [False] * n
    i = 0
    while i < n:
        hw = hws[i]
        if is32(hw) and i + 1 < n:
            hw2 = hws[i + 1]
            # BL / BLX / B.W T3/T4: first 11110xxx, second 1xxx
            if (hw & 0xF800) == 0xF000 and (hw2 & 0x8000) == 0x8000:
                mask[i] = mask[i + 1] = True
            # MOVW / MOVT (T3): 11110 i 10 x100 imm4 | 0 imm3 Rd imm8
            elif (hw & 0xFB70) in (0xF240, 0xF2C0) and (hw2 & 0x8000) == 0:
                mask[i] = mask[i + 1] = True
            # LDR.W literal: F8DF / F85F
            elif (hw & 0xFF7F) == 0xF85F:
                imm = hw2 & 0xFFF
                up = hw & 0x0080
                pc = (start_addr + 2 * i + 4) & ~3
                tgt = pc + imm if up else pc - imm
                off = (tgt - start_addr) // 2
                for k in (off, off + 1):
                    if 0 <= k < n:
                        mask[k] = True
            i += 2
            continue
        # 16-bit LDR literal: 01001 Rt imm8
        if (hw & 0xF800) == 0x4800:
            imm = (hw & 0xFF) * 4
            pc = (start_addr + 2 * i + 4) & ~3
            off = (pc + imm - start_addr) // 2
            for k in (off, off + 1):
                if 0 <= k < n:
                    mask[k] = True
        i += 1
    return [None if m else h for h, m in zip(hws, mask)]


def main():
    vml, img_path, base_hex, out = sys.argv[1:5]
    base = int(base_hex, 16)
    img = open(img_path, 'rb').read()
    ih = [img[2 * i] | (img[2 * i + 1] << 8) for i in range(len(img) // 2)]
    # index: pair of consecutive halfwords -> positions
    index = defaultdict(list)
    for p in range(len(ih) - 1):
        index[(ih[p], ih[p + 1])].append(p)

    with open(vml, 'rb') as f:
        elf = ELFFile(f)
        secs = [s for s in elf.iter_sections() if s['sh_type'] == 'SHT_PROGBITS'
                and s['sh_flags'] & 0x4]  # SHF_EXECINSTR
        symtab = elf.get_section_by_name('.symtab')
        funcs = {}
        for sym in symtab.iter_symbols():
            if sym['st_info']['type'] != 'STT_FUNC' or sym['st_size'] < MIN_SIZE:
                continue
            addr = sym['st_value'] & ~1
            funcs.setdefault((addr, sym['st_size']), sym.name)
        secdata = [(s['sh_addr'], s['sh_size'], s.data()) for s in secs]

    def code_at(addr, size):
        for a, sz, d in secdata:
            if a <= addr and addr + size <= a + sz:
                return d[addr - a: addr - a + size]
        return None

    stats = defaultdict(int)
    with open(out, 'w') as o:
        o.write('name\tvml_addr\tsize\tstatus\timage_addrs\n')
        for (addr, size), name in sorted(funcs.items()):
            code = code_at(addr, size)
            if code is None:
                continue
            sig = build_sig(code, addr)
            # anchor: first two consecutive unmasked halfwords
            anchor = None
            for k in range(len(sig) - 1):
                if sig[k] is not None and sig[k + 1] is not None:
                    anchor = k
                    break
            hits = []
            if anchor is not None:
                for p in index.get((sig[anchor], sig[anchor + 1]), ()):
                    s0 = p - anchor
                    if s0 < 0 or s0 + len(sig) > len(ih):
                        continue
                    if all(h is None or h == ih[s0 + j] for j, h in enumerate(sig)):
                        hits.append(base + 2 * s0)
                        if len(hits) > 8:
                            break
            status = 'none' if not hits else ('unique' if len(hits) == 1 else 'multi')
            stats[status] += 1
            o.write(f'{name}\t{addr:#x}\t{size}\t{status}\t'
                    + ','.join(f'{h:#x}' for h in hits) + '\n')
    print(dict(stats), file=sys.stderr)


if __name__ == '__main__':
    main()

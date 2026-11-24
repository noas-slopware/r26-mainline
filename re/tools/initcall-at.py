#!/usr/bin/env python3
"""initcall-at.py <vmlinux> <n> [context]: name the n-th initcall (1-based) in
the order do_one_initcall runs them (__initcall_start..__initcall_end)."""
import subprocess, sys, struct
vml, n = sys.argv[1], int(sys.argv[2], 0)
ctx = int(sys.argv[3]) if len(sys.argv) > 3 else 3
syms = {}
for l in subprocess.run(['llvm-nm', vml], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 3:
        syms.setdefault(p[2], int(p[0], 16))
addr2sym = {}
for name, a in syms.items():
    addr2sym.setdefault(a & ~1, name)
s, e = syms['__initcall_start'], syms['__initcall_end']
secs = subprocess.run(['llvm-readelf', '-S', '-W', vml], capture_output=True, text=True).stdout.splitlines()
for l in secs:
    p = l.replace('[ ', '[').split()
    if len(p) > 5 and p[2] == 'PROGBITS':
        sa, off, sz = int(p[3], 16), int(p[4], 16), int(p[5], 16)
        if sa <= s < sa + sz:
            break
data = open(vml, 'rb').read()
ptrs = [struct.unpack_from('<I', data, off + (x - sa))[0] for x in range(s, e, 4)]
levels = {syms[k]: k for k in syms if k.startswith('__initcall') and k.endswith('_start')}
print(f'{len(ptrs)} initcalls')
for i in range(max(1, n - ctx), min(len(ptrs), n + ctx) + 1):
    a = s + 4 * (i - 1)
    lv = max((v for v in levels if v <= a), default=None)
    print(f"{'=>' if i == n else '  '} {i:4d} {levels.get(lv, '?'):22s} {addr2sym.get(ptrs[i-1] & ~1, hex(ptrs[i-1]))}")

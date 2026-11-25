# Licenses

| path | license | notes |
|---|---|---|
| `patches/linux/` | GPL-2.0-only | Linux. Text in `GPL-2.0-only.txt`. New files in the patches carry SPDX headers. |
| `config/` | GPL-2.0-only | kernel configuration fragments, part of the kernel build |
| `userspace/` | MIT | SPDX header in each file. Text in `MIT.txt`. |
| `tools/bringup/loader/r26kexec.c` | GPL-2.0 | SPDX header in the file |
| `tools/` other files | not stated | no header in these files |
| `docs` branch | not stated | no header in the documents; `docs/re/tools/spinand-dump`, `riubc.c`, `r26peek` carry GPL-2.0 headers |
| `alpine` branch | per package | each `APKBUILD` has its own `license=` line; the scripts in its `tools/` carry MIT headers |
| `ci` branch | MIT | SPDX headers in the workflow and scripts |

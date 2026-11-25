# Alpine root filesystem for the R26

`build.sh` builds a 512 MiB ext4 image (label `alpine`) with Alpine Linux (latest stable, armv7) to
replace the Debian 12 root on the card. It needs no root: the root is assembled in a user namespace,
armv7 package scripts run through qemu-user binfmt, and `mkfs.ext4 -d` writes the files with their
numeric owners.

```sh
./build.sh debian-root.tar raat-endpoint /path/to/alpine-r26.ext4
```

The Debian tar supplies the box's identity: hostname, `/etc/hosts`, timezone, `/etc/machine-id`, the
SSH host keys, root's `authorized_keys`, the NTP sources, `/var/lib/raat-endpoint` and the DHCP client
id. The client id is computed the way systemd-networkd does it (0xff, the pinned IAID from
`eth0.network`, DUID-EN from the machine id), so the router hands out the same lease. Set `CLIENT_ID`
to override it. Nothing secret lives in this directory; the image does hold the host keys, so it is
written mode 600.

Host requirements: `qemu-user-static` with the qemu-arm binfmt (F flag), util-linux `unshare`,
65535 subordinate ids in `/etc/subuid` and `/etc/subgid`, e2fsprogs, curl, python3. If gpg has
Alpine's release key (`0482D840…07D9495A`), the minirootfs signature is checked too; the sha256 is
always checked against `latest-releases.yaml` and the `.sha256` file.

## What is in it

Packages: `alpine-base`, `mdevd-openrc`, `openssh-server`, `chrony`, `e2fsprogs`, `tzdata`. No
compilers, no docs.

| Runlevel | Services |
|---|---|
| sysinit | devfs, dmesg, cgroups, mdevd, mdevd-init, hw-watchdog |
| boot | osclock, fsck, root, localmount, bootmisc, hostname, sysctl, syslog, seedrng, networking |
| default | sshd, chronyd, raat-endpoint |
| shutdown | killprocs, savecache, mount-ro |

- `hw-watchdog`: busybox `watchdog -T 30 -t 10 /dev/watchdog` under supervise-daemon, started in
  sysinit with no dependencies, since the kernel resets the board if nothing opens the watchdog within
  120 s. BusyBox `watchdog` does a magic close when it is stopped at shutdown; the kernel's `nowayout`
  keeps the watchdog running anyway, so a hang late in the shutdown still ends in a reset.
- `raat-endpoint`: supervise-daemon with unlimited respawns, stdout and stderr to syslog through
  `logger`, `ulimit -r 95` for its SCHED_RR thread and a 64 MiB `memory.max` (cgroup v2 only).
- mdevd instead of busybox mdev: the kernel has no uevent helper (`CONFIG_UEVENT_HELPER=n`), and
  mdevd listens on netlink.
- syslog is busybox `syslogd -C64`, a 64 KiB ring in RAM (`logread`), so no logs reach the card.
- sshd accepts keys only (`PermitRootLogin prohibit-password`). Root has no password (`*`, not `!`,
  which sshd without PAM would treat as locked), so the ttyS0 getty cannot log root in.
- `eth0`: DHCP through ifupdown-ng and udhcpc, with option 61 and the hostname from Debian.
- The root is mounted by label (`LABEL=alpine`) in fstab. The clock provider is `osclock`, since the
  kernel already reads the RTC (`RTC_HCTOSYS`). Nothing writes the RTC back: the kernel has no
  `RTC_SYSTOHC`, so chrony's `rtcsync` has no effect.

## Before booting it

- The stock U-Boot loads `/GustardCore` and `/00` from this filesystem. Pass `KERNEL_IMAGE` and
  `KERNEL_DTB` to include them, or copy them in afterwards.
- The feature set is deliberately old (`has_journal ext_attr resize_inode dir_index filetype extent
  flex_bg sparse_super large_file huge_file dir_nlink extra_isize`; no `metadata_csum`, `64bit` or
  `orphan_file`) so that U-Boot 2022.07 and the stock 4.9 kernel can read it. Compare it with
  `tune2fs -l` of the card's current partition. Grow it with `resize2fs` if the partition is larger.
- U-Boot passes `root=/dev/mmcblk0p1 rw`. The kernel from `./build.sh alpine` appends
  `root=PARTUUID=... ro` (`config/r26-alpine.config`), so the root is p2 and starts read-only: fsck runs,
  then the `root` service remounts it read-write.
- The kernel derives the MAC from the SoC unique ID, so it is the same at every boot. udhcpc releases
  the lease at shutdown (ifupdown-ng passes `-R`), and the router then hands out an address by MAC:
  stable as long as the MAC is.
- Alpine's `dmesg` service sets the console loglevel to 1, which also silences netconsole after init.

# alpine

Alpine Linux packages and the SD card image for the Gustard R26 streamer, built with Alpine's own
`abuild`. One directory per package, as in aports.

| package | version | what |
|---|---|---|
| `linux-gustard-r26` | 7.3.6-r0 | stable Linux 7.3.6 plus the 26-patch series (the same files as `patches/linux` on the `senpai` branch) with `config/r26.config` from there, on `allnoconfig`. Two images that differ only in the built-in command line: `zImage` (root on the card's first partition) and `zImage-root-p2` (root on the second, for cards that keep the stock Debian on the first) |
| `device-gustard-r26` | 1-r0 | `r26-boot-deploy` and its apk trigger (puts the kernel and DTB where the stock U-Boot loads them, `/GustardCore` and `/00`, keeping the old pair as `.old`), the `hw-watchdog` OpenRC service (BusyBox `watchdog` on the kernel's nowayout watchdog). Subpackage `-repo`: this repository and its signing key |
| `raat-endpoint` | 0.1.0-r0 | [raat-endpoint](https://github.com/noas-slopware/raat-endpoint) v0.1.0, the native RAAT (Roon Ready) endpoint, with its OpenRC service in `raat-endpoint-openrc` |

The packages are published as a signed apk repository by the workflow on the `ci` branch:
`https://noas-slopware.github.io/r26-mainline/alpine/v3.24/gustard-r26`, mirrored at
`https://mirror.funami.tech/r26-mainline/alpine/v3.24/gustard-r26` (key
`r26-mainline-1cc0db58.rsa.pub`, also in `device-gustard-r26/`).

## How the kernel gets booted

The stock U-Boot in the on-board SPI NAND loads `/GustardCore` (a plain zImage) and `/00` (the DTB)
from the root of the card's first partition and always passes `root=/dev/mmcblk0p1 rw`. The
kernel's built-in command line is appended after that, so it can only add to it or override it.
`r26-boot-deploy` picks the image that matches the partition the running system is on:

| this system's root | image | written to |
|---|---|---|
| `mmcblk0p1` | `zImage` (adds `ro`, so fsck can run before the `root` service remounts it) | `/GustardCore`, `/00` of this system |
| `mmcblk0p2` | `zImage-root-p2` (adds `root=/dev/mmcblk0p2 ro`) | `/GustardCore`, `/00` of the first partition, mounted for the copy |
| anything else | none | nothing; it says so |

In a chroot that is not an R26 (an image build), it writes the first layout into that root.

## Building

```sh
tools/abuild-docker.sh ~/r26-repo linux-gustard-r26 raat-endpoint device-gustard-r26
```

builds the packages in an armv7 Alpine 3.24 container (docker; through qemu-user on an x86_64 or
arm64 host) into `~/r26-repo/gustard-r26/armv7/`. Without `R26_PRIVKEY` they are signed with a
throwaway key, which is fine for testing and nothing else. `tools/abuild-docker.sh --checksum <package>`
rewrites a package's `sha512sums`. The kernel takes a while under emulation; `R26_CCACHE` and
`R26_DISTFILES` keep the compiler cache and the downloads between runs.

## The image

```sh
tools/mkimage-r26.sh ~/r26-images
```

builds `alpine-gustard-r26-<date>.img.zst` from the published repository: an MBR with one ext4
partition (label `alpine`, from sector 2048, with the conservative feature set the stock U-Boot
2022.07 can read) holding Alpine 3.24 with OpenRC, mdevd, chrony, OpenSSH (keys only), BusyBox
syslog in RAM, `device-gustard-r26` and `raat-endpoint`. It writes to the card as little as it can: `noatime` and `commit=60` on the
root, `/tmp` and `/var/tmp` in RAM, syslog in RAM, no swap, no chrony drift file. What still
writes: the SSH host keys and the Roon identity once, raat-endpoint's settings when the Core
changes them, the RNG seed at boot and shutdown, and `apk upgrade`. Root has no password and there is no SSH
key: you put yours on the card before the first boot. SSH host keys and the Roon identity are made
on the first boot. `tools/verify-image.sh` checks for all of that before the image is packed;
`R26_VERIFY_DENY=<file>` adds your own strings (hostnames, addresses) to refuse.

With `R26_LOCAL_REPO=<repo dir>` (and `R26_LOCAL_KEY=<public key>` for a throwaway-signed one)
the image comes from a local build instead. Those files are named `NOT-FOR-RELEASE-*`: the image's
apk database would then name packages that the published repository does not have.

Installing is described in the README on the `senpai` branch.

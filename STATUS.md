# Status

As of 2026-11-25. Kernel: stable v7.3.6 plus the 26 patches in `patches/linux/`.

## What runs on the R26

- **Boot:** stock IPL and U-Boot (on-board SPI NAND, untouched), then `/GustardCore` + `/00` from the
  card. No shim.
- **Userland:** Alpine 3.24 on the card's second partition (`alpine/`). OpenRC, mdevd, chrony, sshd
  with keys only, BusyBox syslog in RAM, and the BusyBox watchdog feeder. 14 MB of RAM in use, against
  40 MB for Debian with the same endpoint and 67 MB for Debian with RoonBridge.
- **Audio:** [raat-endpoint](https://github.com/noas-slopware/raat-endpoint) on `hw:CARD=G20`, bit-perfect
  PCM. The Core finds it about 11 s after boot.
- **Fallback userland:** the stock Debian 12 on the first partition, with the endpoint installed and
  RoonBridge disabled (not removed). `/GustardCore.debian` on the card is the same kernel with the
  base command line; copy it over `/GustardCore` and reboot to get Debian. This was checked on the box.
- **Stock:** `/GustardCore.stock` + `/00.stock`. They match the original card's checksums.

## Packages and image

- The Alpine packages (`linux-gustard-r26`, `device-gustard-r26`, `raat-endpoint`) are built from
  the `alpine` branch by the `ci` branch's workflow and published as a signed apk repository on
  GitHub Pages. The kernel package is the same series and fragment as the kernel above, built by
  Alpine's abuild.
- The card image (`alpine-gustard-r26-<date>.img.zst`, releases) is made from that repository.
  It puts Alpine on the card's first partition. That layout with the packaged kernel has not been
  booted on the box yet: the box itself runs the second-partition layout, with the same kernel
  series built by `build.sh alpine`.

## Verified on the box

| What | How |
|---|---|
| Ethernet TX | 3 x 300 MiB random data over raw TCP and 200 MiB over SSH: sha256 equal at both ends, 0 TCP checksum errors at the receiver (the old TX path gave about 14,800 per 300 MiB). 8.3 MB/s |
| Ethernet RX | 300 MiB in: sha256 equal, 0 checksum errors, 0 RX errors |
| Watchdog | stopping the feeder is refused ("nowayout prevents watchdog being stopped!") and the board resets 30 s later |
| Reboots | 13 OpenRC reboots from Alpine across the test and final kernels (6 in a row on one), each back in 33 to 40 s |
| CPU core voltage | the VID pads read back as the 900 mV state; the pad muxes on them are clear |
| Playback | 44.1 and 96 kHz through the endpoint, pause and resume |

## Open

- **A reboot hang, cause unknown.** The first reboot from Alpine hung with the watchdog switched off
  by the feeder's magic close. The driver now honours `nowayout`, so a hang anywhere up to the reset
  ends in a reset. The hang never came back, but its conditions were not reproduced either. A hang in
  IPL or U-Boot is not covered: nothing arms the watchdog there.
- **The IP address moves.** ifupdown-ng runs `udhcpc -R`, which gives the lease back at every shutdown,
  and the router then picks an address by MAC. Starting udhcpc without `-R` would keep it.
- **Analog power-down not ported.** Stock switches off the unused HDMI, video DAC, display PLL, MIPI
  D-PHY and SATA analog blocks at init. On mainline, reading one of those banks stalled the bus and froze
  the board; which one was not bisected.
- **`clk_ignore_unused` stays.** U-Boot forces it on the command line, so unused clocks are never
  switched off. The clock tree has not been audited for running without it.
- **Untested:** sample rates above 96 kHz, grouped zones, link flaps after a cable replug (stock had a
  PHY re-train loop and an autoneg restart that are not ported), USB error recovery (stock re-probed the
  controller).
- **Unknown board wiring:** the UART0 pins, the TTL0 pad (the SD power pin on the reference design,
  undriven here), what GPIO12 does (held low, as U-Boot leaves it).

## Tracking stable

Rebase onto each new 7.3.y. Move to 7.4.y only after 7.4 is released.

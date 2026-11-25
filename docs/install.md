# Installing Alpine on the Gustard R26

This puts Alpine Linux with the mainline kernel and [raat-endpoint](https://github.com/noas-slopware/raat-endpoint)
on the streamer's microSD card. Read the whole page first.

## What changes

- **The card is replaced, the box is not.** The streamer boots from its microSD card: the stock
  bootloader in the on-board flash loads `/GustardCore` (kernel) and `/00` (device tree) from the
  card's first partition. Nothing here writes to the on-board flash, so going back is putting
  Gustard's card contents back.
- **Roon only.** The image plays to Roon through raat-endpoint (it shows up in Roon like any Roon
  Ready device). Gustard's own system also runs Tidal Connect, Spotify Connect, AirPlay and NAA;
  none of those are in this image.
- **No display or front-panel changes.** The front panel is its own microcontroller; the image
  does not talk to it and does not need to.

## You need

- A Linux machine and a USB-C cable (the card's file system is ext4, so it has to be Linux).
- `zstd`, `sha256sum`, and for growing the partition `parted` and `e2fsprogs`.
- Your SSH public key: the image has no password and no other way in.
- The image from the
  [latest release](https://github.com/noas-slopware/r26-mainline/releases): `alpine-gustard-r26-<date>.img.zst`
  and `sha256sums`.

## Steps

1. **Connect the card.** No need to open the box or take the card out: the USB-C service port on
   the back of the R26 shows the card as a USB drive (a Genesys GL `05e3:0752` reader behind a hub;
   the same port carries the front-panel MCU's UART for its firmware updates). Connect it to your
   Linux machine. Never write to the card while the streamer is running from it. The card itself
   sits in a hinged socket inside; opening the box is only for replacing a dead card.

2. **Back up the whole card**, so you can always go back:

   ```sh
   sudo dd if=/dev/sdX of=r26-card-backup.img bs=4M status=progress
   ```

   (`/dev/sdX` is the card; check with `lsblk` before every `dd`.)

3. **Check and write the image:**

   ```sh
   sha256sum -c --ignore-missing sha256sums
   zstdcat alpine-gustard-r26-<date>.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```

4. **Grow the partition** to the whole card (optional; the image is 768 MiB):

   ```sh
   sudo parted /dev/sdX resizepart 1 100%
   sudo e2fsck -f /dev/sdX1
   sudo resize2fs /dev/sdX1
   ```

   Keep the file system's feature set as it is (no `tune2fs -O metadata_csum,64bit`): the stock
   bootloader reads the kernel from it and knows only the older ext4 features.

5. **Put your SSH key on it:**

   ```sh
   sudo mount /dev/sdX1 /mnt
   sudo install -m 600 ~/.ssh/id_ed25519.pub /mnt/root/.ssh/authorized_keys
   sudo umount /mnt
   ```

6. **Boot.** Unplug the USB-C cable and power the R26 on. It takes an address by DHCP with the hostname
   `gustard-r26`; find it in your router's leases, then `ssh root@<address>`. The first boot makes
   the SSH host keys, so the first login asks you to accept a new key. The MAC address comes from
   the SoC's unique ID and stays the same across boots.

7. **Roon.** In Roon, Settings > Audio: the R26's DAC appears as a new Roon Ready device. Enable it
   and name the zone. Taking over the zone RoonBridge had on the stock system is possible by
   copying RoonBridge's identity; see "Installing in place of RoonBridge" in the raat-endpoint README.

## Card wear

The image writes to the card as little as it can: the root is mounted `noatime` with ext4 journal
commits batched to a minute (`commit=60`), `/tmp` and `/var/tmp` are in RAM, syslog keeps its log
in RAM (`logread`), there is no swap, and chrony keeps no drift file. What still writes: the SSH host
keys and the Roon identity once, raat-endpoint's settings when the Core changes them, the random
seed at boot and shutdown, and `apk upgrade`. Keep it that way when you add things: send logs to
syslog rather than to files under `/var/log`, and leave swap off.

## Updates

```sh
apk update && apk upgrade
```

The image already has this repository (`device-gustard-r26-repo`). A new kernel puts itself where
the bootloader loads it (`r26-boot-deploy`, run by the package's trigger) and keeps the previous
pair as `/GustardCore.old` and `/00.old`.

**If a new kernel does not boot**, connect the USB-C service port and copy the old pair back:

```sh
sudo mount /dev/sdX1 /mnt
sudo cp /mnt/GustardCore.old /mnt/GustardCore && sudo cp /mnt/00.old /mnt/00
sudo umount /mnt
```

## Going back to the stock system

Write your backup back: `sudo dd if=r26-card-backup.img of=/dev/sdX bs=4M conv=fsync status=progress`.

## Keeping Gustard's system next to Alpine

The packages also work with Alpine on the card's second partition and the stock Debian left on the
first. The bootloader always loads the kernel from the first partition and passes `root=/dev/mmcblk0p1`;
on such a system `r26-boot-deploy` writes `zImage-root-p2` (built-in `root=/dev/mmcblk0p2 ro`) into
the first partition instead. Save the stock pair under names nothing overwrites first
(`/GustardCore.stock`, `/00.stock`): the deploy only keeps one `.old`. Booting Debian again is
copying the stock pair back over `/GustardCore` and `/00`. There is no image for this layout;
`tools/alpine-from-debian` on the `senpai` branch builds an Alpine root from a running Debian box,
keeping its SSH keys, DHCP client id and Roon identity.

## Not covered

- What the image does on hardware is in the release notes of each release; the kernel's state is in
  `STATUS.md` on the `senpai` branch.
- Sample rates above 96 kHz and grouped zones have not been tried.

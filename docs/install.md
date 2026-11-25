# Installing Alpine on the Gustard R26

This puts Alpine Linux with the mainline kernel and [raat-endpoint](https://github.com/noas-slopware/raat-endpoint)
on the streamer's microSD card. Read the whole page before you start.

## What changes

- **The card changes, the box doesn't.** The streamer boots from its microSD card. The stock
  bootloader in the on-board flash loads `/GustardCore` (kernel) and `/00` (device tree) from the
  card's first partition. Nothing here touches the on-board flash, so going back is just writing
  Gustard's own card image again.
- **Roon only.** The image plays to Roon through raat-endpoint, so it shows up in Roon like any
  Roon Ready device. Gustard's own system also runs Tidal Connect, Spotify Connect, AirPlay, and NAA.
  None of those are in this image.
- **No display or front-panel changes.** The front panel is its own microcontroller anyway, so the
  image doesn't talk to it and doesn't need to.

## You need

- A Linux machine and a USB-C cable (the card uses ext4, so yes, it has to be Linux).
- `zstd` and `sha256sum`, plus `parted` and `e2fsprogs` if you want to grow the partition.
- Your SSH public key. The image has no password and no other way in.
- The image from the
  [latest release](https://github.com/noas-slopware/r26-mainline/releases): `alpine-gustard-r26-<date>.img.zst`
  and `sha256sums`.

## Steps

1. **Connect the card.** No need to open the box or pull the card out. The USB-C service port on
   the back of the R26 shows the card as a USB drive (a Genesys GL `05e3:0752` reader behind a hub,
   and the same port also carries the front-panel MCU's UART for its firmware updates). Connect it to
   your Linux machine. Never write to the card while the streamer is running from it. The card
   itself sits in a hinged socket inside, so opening the box is only for replacing a dead card.

2. **Check and write the image.** Replace `/dev/sdX` with your card device (check with `lsblk`
   before every `dd`):

   ```sh
   sha256sum -c --ignore-missing sha256sums
   zstdcat alpine-gustard-r26-<date>.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```

3. **Grow the partition** to the whole card (optional, the image is 768 MiB):

   ```sh
   sudo parted /dev/sdX resizepart 1 100%
   sudo e2fsck -f /dev/sdX1
   sudo resize2fs /dev/sdX1
   ```

   Keep the file system's feature set as it is (no `tune2fs -O metadata_csum,64bit`). The stock
   bootloader reads the kernel from it and only knows older ext4 features.

4. **Put your SSH key on it:**

   ```sh
   sudo mount /dev/sdX1 /mnt
   sudo install -m 600 ~/.ssh/id_ed25519.pub /mnt/root/.ssh/authorized_keys
   sudo umount /mnt
   ```

5. **Boot.** Unplug the USB-C cable and power the R26 on. It gets an address by DHCP with the
   hostname `gustard-r26`. Find it in your router's leases, then `ssh root@<address>`. First boot
   generates the SSH host keys, so the first login asks you to accept a new key. The MAC address
   comes from the SoC's unique ID and stays the same across boots.

6. **Roon.** In Roon, Settings > Audio, the R26's DAC shows up as a new Roon Ready device. Enable
   it and name the zone. If you want to take over the zone RoonBridge had on the stock system, copy
   RoonBridge's identity over (see "Installing in place of RoonBridge" in the raat-endpoint README).

## Card wear

The image writes to the card as little as possible. Root is mounted `noatime` with ext4 journal
commits batched to one minute (`commit=60`), `/tmp` and `/var/tmp` live in RAM, syslog logs to RAM
(`logread`), swap is off, and chrony keeps no drift file. The things that still write are the SSH
host keys and Roon identity (once), raat-endpoint's settings when the Core changes them, the random
seed at boot and shutdown, and `apk upgrade`. Keep it that way when you add things: send logs to
syslog rather than files under `/var/log`, and leave swap off.

## Updates

```sh
apk update && apk upgrade
```

This repository is already set up in the image (`device-gustard-r26-repo`). When a kernel updates,
the package trigger runs `r26-boot-deploy` to put the new one where the bootloader loads it and
keeps the previous pair as `/GustardCore.old` and `/00.old`.

**If a new kernel doesn't boot**, plug in the USB-C service port and copy the old pair back:

```sh
sudo mount /dev/sdX1 /mnt
sudo cp /mnt/GustardCore.old /mnt/GustardCore && sudo cp /mnt/00.old /mnt/00
sudo umount /mnt
```

## Going back to the stock system

Grab Gustard's firmware image for the R26 (from Gustard, e.g. `R26_1v43.img.gz` in their 1.43
zip) and write it back onto the card with `zcat R26_1v43.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`.

## Keeping Gustard's system next to Alpine

The packages also work if you put Alpine on the card's second partition and leave stock Debian on
the first. The bootloader always loads the kernel from the first partition and passes
`root=/dev/mmcblk0p1`, so on that setup `r26-boot-deploy` writes `zImage-root-p2` (built-in
`root=/dev/mmcblk0p2 ro`) into the first partition instead. Back up the stock pair first under names
nothing overwrites (`/GustardCore.stock`, `/00.stock`), because deploy only keeps one `.old`.
Booting Debian again is just copying those stock files back over `/GustardCore` and `/00`. There
isn't an image for this layout. Use `tools/alpine-from-debian` on the `senpai` branch to build an
Alpine root from a running Debian box while keeping its SSH keys, DHCP client id, and Roon identity.

## Not covered

- What the image does on hardware is in the release notes for each release, and the kernel's state is
  in `STATUS.md` on the `senpai` branch.
- Sample rates above 96 kHz and grouped zones haven't been tried.

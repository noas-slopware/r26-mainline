#!/bin/sh
# Build an Alpine Linux (armv7) root filesystem image for the Gustard R26 streamer.
#
#   ./build.sh DEBIAN_ROOT_TAR RAAT_ENDPOINT [OUTPUT.ext4]
#
# DEBIAN_ROOT_TAR  tar of the running Debian root; the box's identity comes from it
#                  (hostname, hosts, timezone, SSH host keys, root's authorized_keys,
#                  /etc/machine-id, DHCP client id, NTP sources, raat-endpoint state)
# RAAT_ENDPOINT    the static raat-endpoint binary
# OUTPUT.ext4      default ./alpine-r26.ext4; a .sha256 is written next to it
#
# Environment:
#   ALPINE_BRANCH  release branch to use (default latest-stable), e.g. v3.24
#   CLIENT_ID      DHCP option 61 as hex; default: derived from the tar's systemd-networkd
#                  setup (0xff + IAID + DUID-EN from /etc/machine-id, as networkd does)
#   KERNEL_IMAGE, KERNEL_DTB  optional: copied to /GustardCore and /00 (the stock U-Boot
#                  loads both from this filesystem)
#   WORK_DIR       download cache (default ~/.cache/r26-alpine)
#
# No sudo: everything runs in a user namespace (needs a 65535-id range in /etc/subuid and
# /etc/subgid), armv7 package scripts run through qemu-arm binfmt (needs the F flag).
set -eu

MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
BRANCH=${ALPINE_BRANCH:-latest-stable}
ARCH=armv7
SIZE=512M
LABEL=alpine
PACKAGES="alpine-base mdevd-openrc openssh-server chrony e2fsprogs tzdata"
# ncopa's Alpine release signing key
GPG_FPR=0482D84022F52DF1C4E7CD43293ACD0907D9495A
# conservative ext4 feature set: the stock U-Boot (2022.07) reads the kernel from this
# filesystem, and the stock 4.9 kernel must still mount it for a rollback
EXT4_FEATURES=none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize

die() { echo "build.sh: $*" >&2; exit 1; }

if [ "${R26_ALPINE_INNER:-}" != 1 ]; then
	[ $# -ge 2 ] || die "usage: $0 DEBIAN_ROOT_TAR RAAT_ENDPOINT [OUTPUT.ext4]"
	for t in curl sha256sum unshare mkfs.ext4 e2fsck tar python3 awk; do
		command -v "$t" >/dev/null || die "missing tool: $t"
	done
	tarball=$(realpath "$1"); endpoint=$(realpath "$2"); out=$(realpath -m "${3:-alpine-r26.ext4}")
	[ -f "$tarball" ] || die "no such tar: $1"
	[ -f "$endpoint" ] || die "no such file: $2"
	case "$(uname -m)" in
	arm*) ;;
	*) grep -qs '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-arm \
		|| die "qemu-arm binfmt with the F flag is needed (qemu-user-static + binfmt)";;
	esac
	work=${WORK_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/r26-alpine}
	mkdir -p "$work/dl" "$work/stage"
	dl=$work/dl

	# --- release: latest-releases.yaml -> minirootfs, sha256 (+ GPG if the key is known)
	curl -fsSL "$MIRROR/$BRANCH/releases/$ARCH/latest-releases.yaml" -o "$dl/latest-releases.yaml"
	eval "$(awk '
		/^-/ { if (fl == "alpine-minirootfs") exit; fl = "" }
		/^  flavor:/ { fl = $2 }
		/^  (branch|version|file|sha256):/ { k = $1; sub(":", "", k); v[k] = $2 }
		END { if (fl == "alpine-minirootfs")
			printf "rel_branch=%s rel_version=%s rel_file=%s rel_sha256=%s\n",
				v["branch"], v["version"], v["file"], v["sha256"] }' "$dl/latest-releases.yaml")"
	[ -n "${rel_file:-}" ] || die "no minirootfs in latest-releases.yaml"
	base=$MIRROR/$rel_branch/releases/$ARCH
	for f in "$rel_file" "$rel_file.sha256" "$rel_file.asc"; do
		[ -s "$dl/$f" ] || curl -fsSL "$base/$f" -o "$dl/$f"
	done
	got=$(sha256sum "$dl/$rel_file" | cut -d' ' -f1)
	[ "$got" = "$rel_sha256" ] || die "sha256 mismatch (yaml) for $rel_file"
	[ "$got" = "$(cut -d' ' -f1 "$dl/$rel_file.sha256")" ] || die "sha256 mismatch (.sha256) for $rel_file"
	echo "Alpine $rel_version ($rel_branch) $ARCH minirootfs: sha256 OK"
	if command -v gpg >/dev/null && gpg --list-keys "$GPG_FPR" >/dev/null 2>&1; then
		gpg --status-fd 1 --verify "$dl/$rel_file.asc" "$dl/$rel_file" 2>/dev/null \
			| grep -q "^\[GNUPG:\] VALIDSIG $GPG_FPR " \
			|| die "GPG signature check failed for $rel_file"
		echo "GPG signature OK"
	else
		echo "warning: Alpine signing key $GPG_FPR not in the keyring; GPG signature not checked" >&2
	fi

	# --- DHCP client id, as systemd-networkd sends it on the Debian box
	if [ -z "${CLIENT_ID:-}" ]; then
		net=$(tar -xOf "$tarball" ./etc/systemd/network/eth0.network 2>/dev/null) \
			|| die "no ./etc/systemd/network/eth0.network in the tar; set CLIENT_ID"
		nd=$(tar -xOf "$tarball" ./etc/systemd/networkd.conf 2>/dev/null || true)
		printf '%s\n%s\n' "$net" "$nd" | grep -Eq '^[[:space:]]*(DUIDType|DUIDRawData|ClientIdentifier)=' \
			&& die "custom DUID/ClientIdentifier in the networkd config; set CLIENT_ID"
		iaid=$(printf '%s\n' "$net" | sed -n 's/^[[:space:]]*IAID=[[:space:]]*//p' | tail -n1)
		[ -n "$iaid" ] || die "no IAID= in eth0.network (networkd would hash the MAC); set CLIENT_ID"
		mid=$(tar -xOf "$tarball" ./etc/machine-id)
		CLIENT_ID=$(python3 -I -c '
import struct, sys
M = (1 << 64) - 1
def rotl(x, b): return ((x << b) | (x >> (64 - b))) & M
def siphash24(key, data):
    k0, k1 = struct.unpack("<QQ", key)
    v = [k0 ^ 0x736f6d6570736575, k1 ^ 0x646f72616e646f6d, k0 ^ 0x6c7967656e657261, k1 ^ 0x7465646279746573]
    def rnd():
        v[0] = (v[0] + v[1]) & M; v[1] = rotl(v[1], 13) ^ v[0]; v[0] = rotl(v[0], 32)
        v[2] = (v[2] + v[3]) & M; v[3] = rotl(v[3], 16) ^ v[2]
        v[0] = (v[0] + v[3]) & M; v[3] = rotl(v[3], 21) ^ v[0]
        v[2] = (v[2] + v[1]) & M; v[1] = rotl(v[1], 17) ^ v[2]; v[2] = rotl(v[2], 32)
    n = len(data) // 8 * 8
    for i in range(0, n, 8):
        m, = struct.unpack("<Q", data[i:i + 8]); v[3] ^= m; rnd(); rnd(); v[0] ^= m
    b = (len(data) & 0xff) << 56 | int.from_bytes(data[n:], "little")
    v[3] ^= b; rnd(); rnd(); v[0] ^= b; v[2] ^= 0xff
    for _ in range(4): rnd()
    return v[0] ^ v[1] ^ v[2] ^ v[3]
# systemd: dhcp_identifier_set_duid_en(), HASH_KEY and SYSTEMD_PEN (43793)
key = bytes.fromhex("80118cc2fe4a03ee3ed60c6f36391409")
h = siphash24(key, bytes.fromhex(sys.argv[1].strip()))
duid = struct.pack(">HI", 2, 43793) + struct.pack("<Q", h)
print("ff" + struct.pack(">I", int(sys.argv[2])).hex() + duid.hex())
' "$mid" "$iaid")
	fi
	printf '%s\n' "$CLIENT_ID" | grep -Eqx '([0-9a-fA-F]{2}){2,}' || die "CLIENT_ID is not hex"

	# --- id ranges for the user namespace: ns root = me, 1..65535 = my subordinate ids
	me=$(id -un); uid=$(id -u); gid=$(id -g)
	su=$(awk -F: -v u="$me" -v i="$uid" '($1 == u || $1 == i) && $3 >= 65535 { print $2; exit }' /etc/subuid)
	sg=$(awk -F: -v u="$me" -v i="$uid" '($1 == u || $1 == i) && $3 >= 65535 { print $2; exit }' /etc/subgid)
	[ -n "$su" ] && [ -n "$sg" ] || die "need 65535 subordinate ids for $me in /etc/subuid and /etc/subgid"

	outdir=$(dirname "$out")
	[ -d "$outdir" ] || mkdir -p -m 700 "$outdir"
	self=$(realpath "$0")
	exec env R26_ALPINE_INNER=1 CLIENT_ID="$CLIENT_ID" REL_FILE="$dl/$rel_file" \
		REL_BRANCH="$rel_branch" REL_VERSION="$rel_version" STAGE="$work/stage" \
		unshare --map-users="0:$uid:1" --map-users="1:$su:65535" \
			--map-groups="0:$gid:1" --map-groups="1:$sg:65535" \
			--setuid 0 --setgid 0 --mount --pid --fork --kill-child \
			"$self" "$tarball" "$endpoint" "$out"
fi

# ---------------------------------------------------------------------------------------
# Inside the user namespace (root here = the invoking user outside).
tarball=$1; endpoint=$2; out=$3
umask 022
R=$STAGE
mount -t tmpfs -o size=768m,mode=0755 r26-alpine "$R"
tx() { tar -xpf "$tarball" -C "$R" --numeric-owner "$@"; }
fromtar() { tar -xOf "$tarball" "$1"; }

# --- base system
tar -xzpf "$REL_FILE" -C "$R" --numeric-owner
echo "$MIRROR/$REL_BRANCH/main" > "$R/etc/apk/repositories"
: > "$R/etc/resolv.conf"
mount --bind /etc/resolv.conf "$R/etc/resolv.conf"
# a private /dev for package scripts: host /dev has locked submounts in a user namespace
mount -t tmpfs -o size=64k,mode=0755 r26-dev "$R/dev"
for n in null zero full random urandom tty; do
	: > "$R/dev/$n"
	mount --bind "/dev/$n" "$R/dev/$n"
done
mount -t proc proc "$R/proc"
chroot "$R" /sbin/apk add --no-cache $PACKAGES
umount "$R/proc"
for n in null zero full random urandom tty; do umount "$R/dev/$n"; done
umount "$R/dev"
umount "$R/etc/resolv.conf"
[ -z "$(ls -A "$R/dev")" ] || die "$R/dev not empty after unmount"

# --- identity from the Debian root
tx ./etc/hostname ./etc/hosts ./etc/machine-id ./root/.ssh ./var/lib/raat-endpoint
tx --wildcards './etc/ssh/ssh_host_*_key' './etc/ssh/ssh_host_*_key.pub'
hostname=$(cat "$R/etc/hostname")
tz=$(fromtar ./etc/timezone)
[ -f "$R/usr/share/zoneinfo/$tz" ] || die "timezone $tz not in tzdata"
ln -sfn "/usr/share/zoneinfo/$tz" "$R/etc/localtime"
echo "$tz" > "$R/etc/timezone"
# no password for root: '*' (never '!': sshd without PAM treats '!' as locked and refuses keys too)
sed -i 's/^root:[^:]*:/root:*:/' "$R/etc/shadow"
grep -q '^root:\*:' "$R/etc/shadow" || die "root password field not '*'"

# --- sshd: keys only
cat > "$R/etc/ssh/sshd_config.d/10-r26.conf" <<'EOF'
# Key authentication only (this file is read before the main sshd_config, first value wins).
PermitRootLogin prohibit-password
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF

# --- network: DHCP on eth0 with Debian's client id and hostname (ifupdown-ng -> udhcpc
# -x hostname:... -x 0x3d:...)
cat > "$R/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
	hostname $hostname
	dhcp-client-id $CLIENT_ID
EOF

# --- chrony: Debian's time sources
sources=$(fromtar ./etc/chrony/chrony.conf | grep -E '^[[:space:]]*(pool|server|peer)[[:space:]]') \
	|| die "no pool/server lines in Debian's chrony.conf"
cat > "$R/etc/chrony/chrony.conf" <<EOF
# NTP sources from the Debian install
$sources
driftfile /var/lib/chrony/chrony.drift
makestep 1 3
maxupdateskew 100.0
rtcsync
cmdport 0
EOF

# --- syslog in RAM only (busybox syslogd -C: shared-memory ring, read with logread)
echo 'SYSLOGD_OPTS="-t -C64"' > "$R/etc/conf.d/syslog"

# --- consoles: no VTs, serial getty only
cat > "$R/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

# --- fstab (by label, so it holds whichever partition the root ends up on)
cat > "$R/etc/fstab" <<EOF
LABEL=$LABEL	/	ext4	rw,noatime	0	1
tmpfs	/tmp	tmpfs	nosuid,nodev,mode=1777,size=32m	0	0
EOF

# --- cgroup v2 only, so raat-endpoint can get its memory.max
sed -i 's/^#rc_cgroup_mode="unified"$/rc_cgroup_mode="unified"/' "$R/etc/rc.conf"
grep -q '^rc_cgroup_mode="unified"$' "$R/etc/rc.conf" || die "could not set rc_cgroup_mode"

# --- hardware watchdog feeder: sysinit, no dependencies (devtmpfs has /dev/watchdog
# before init starts; the kernel resets the board if nobody opens it within 120 s)
cat > "$R/etc/init.d/hw-watchdog" <<'EOF'
#!/sbin/openrc-run

description="Feed the hardware watchdog (busybox watchdog)"
supervisor=supervise-daemon
command=/sbin/watchdog
command_args="-F -T 30 -t 10 /dev/watchdog"
respawn_delay=1
respawn_max=0

depend() {
	keyword -docker -lxc -podman -prefix -systemd-nspawn -vserver -wsl
}
EOF

# --- raat-endpoint
install -D -m 0755 -o 0 -g 0 "$endpoint" "$R/usr/local/bin/raat-endpoint"
cat > "$R/etc/init.d/raat-endpoint" <<'EOF'
#!/sbin/openrc-run

description="Native RAAT (Roon Ready) audio endpoint"
supervisor=supervise-daemon
command=/usr/local/bin/raat-endpoint
command_args="-d /var/lib/raat-endpoint"
respawn_delay=2
respawn_max=0
output_logger="logger -t raat-endpoint -p daemon.info"
error_logger="logger -t raat-endpoint -p daemon.info"

depend() {
	# the DAC is watched through /dev/snd and the endpoint re-announces when an
	# address appears, so the network is wanted but not required
	use net logger
}
EOF
cat > "$R/etc/conf.d/raat-endpoint" <<'EOF'
# the ALSA thread runs SCHED_RR 95
rc_ulimit="-r 95"
# 64 MiB, as MemoryMax=64M in the systemd unit
rc_cgroup_settings="
memory.max 67108864
"
EOF
chmod 0755 "$R/etc/init.d/hw-watchdog" "$R/etc/init.d/raat-endpoint"

# --- optional kernel for the stock U-Boot
[ -z "${KERNEL_IMAGE:-}" ] || install -m 0644 -o 0 -g 0 "$KERNEL_IMAGE" "$R/GustardCore"
[ -z "${KERNEL_DTB:-}" ] || install -m 0644 -o 0 -g 0 "$KERNEL_DTB" "$R/00"

# --- runlevels
add() {
	lvl=$1; shift
	for s in "$@"; do
		[ -e "$R/etc/init.d/$s" ] || die "no service $s"
		ln -sfn "/etc/init.d/$s" "$R/etc/runlevels/$lvl/$s"
	done
}
add sysinit devfs dmesg cgroups mdevd mdevd-init hw-watchdog
# osclock: the kernel already set the time from the RTC (RTC_HCTOSYS); it cannot fail
add boot osclock fsck root localmount bootmisc hostname sysctl syslog seedrng networking
add default sshd chronyd raat-endpoint
add shutdown killprocs savecache mount-ro

echo "--- runlevels"
for l in sysinit boot default shutdown; do echo "$l: $(ls "$R/etc/runlevels/$l" | tr '\n' ' ')"; done
echo "--- installed: $(chroot "$R" /sbin/apk info 2>/dev/null | sort | tr '\n' ' ')"
echo "--- root size: $(du -sh "$R" | cut -f1)"

# --- image
umask 077
: > "$out"
mkfs.ext4 -q -F -t ext4 -O "$EXT4_FEATURES" -I 256 -m 1 -L "$LABEL" -d "$R" "$out" "$SIZE"
e2fsck -fn "$out"
( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
echo "Alpine $REL_VERSION image: $out"
cat "$out.sha256"

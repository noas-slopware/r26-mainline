#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# abuild-docker.sh: build packages of this branch for armv7 with Alpine's own abuild, in an
# armv7 Alpine container (docker; on an x86_64 or arm64 host the container runs through
# qemu-user binfmt, e.g. docker/setup-qemu-action or qemu-user-static).
#
#   tools/abuild-docker.sh <repo dir> <package>...      build, in order, into <repo dir>
#   tools/abuild-docker.sh --checksum <package>...      (re)write sha512sums= of the APKBUILDs
#
# <repo dir> is an abuild REPODEST: packages land in <repo dir>/gustard-r26/armv7/ with a
# signed APKINDEX.tar.gz, and each build sees the packages built before it.
#
# Environment:
#   R26_PRIVKEY      file with the repository's private key (CI: the R26_REPO_PRIVKEY secret);
#                    without it a throwaway key signs the packages (local test builds only)
#   R26_KEY_NAME     key name (default r26-mainline-1cc0db58.rsa, as in keys/ on the ci branch)
#   ALPINE_VERSION   default 3.24
#   R26_CCACHE       host directory for a persistent ccache (optional)
#   R26_DISTFILES    host directory for downloaded sources (optional; abuild's SRCDEST)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ver=${ALPINE_VERSION:-3.24}
keyname=${R26_KEY_NAME:-r26-mainline-1cc0db58.rsa}
image=alpine:$ver

# fixed work directories (literal paths only: they are also the only paths this script removes)
checksum=false
if [ "${1:-}" = --checksum ]; then
	checksum=true; shift; out=/var/tmp/r26-abuild-checksum
	rm -rf /var/tmp/r26-abuild-checksum
else
	out=$(realpath -m "$1"); shift
fi
[ $# -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }
mkdir -p "$out"
for p in "$@"; do [ -f "$here/$p/APKBUILD" ] || { echo "no package $p" >&2; exit 1; }; done

keydir=/var/tmp/r26-abuild-keys
rm -rf /var/tmp/r26-abuild-keys
mkdir -m 700 /var/tmp/r26-abuild-keys
trap 'rm -rf /var/tmp/r26-abuild-keys' EXIT
if [ -n "${R26_PRIVKEY:-}" ]; then
	install -m 600 "$R26_PRIVKEY" "$keydir/$keyname"
	openssl rsa -in "$keydir/$keyname" -pubout -out "$keydir/$keyname.pub" 2>/dev/null
	cmp -s "$keydir/$keyname.pub" "$here/device-gustard-r26/$keyname.pub" \
		|| { echo "R26_PRIVKEY does not match device-gustard-r26/$keyname.pub" >&2; exit 1; }
else
	keyname=throwaway-test.rsa
	openssl genrsa -out "$keydir/$keyname" 2048 2>/dev/null
	openssl rsa -in "$keydir/$keyname" -pubout -out "$keydir/$keyname.pub" 2>/dev/null
	echo "no R26_PRIVKEY: signing with a throwaway key (test build, not for publishing)" >&2
fi
chmod 644 "$keydir/$keyname.pub"

ccache_args=()
[ -z "${R26_CCACHE:-}" ] || { mkdir -p "$R26_CCACHE"; ccache_args=(-v "$(realpath "$R26_CCACHE"):/ccache" -e CCACHE_DIR=/ccache); }
[ -z "${R26_DISTFILES:-}" ] || { mkdir -p "$R26_DISTFILES"; ccache_args+=(-v "$(realpath "$R26_DISTFILES"):/var/cache/distfiles"); }

docker run --rm --platform linux/arm/v7 \
	-v "$here:/src:ro" -v "$out:/repo" -v "$keydir:/keys:ro" "${ccache_args[@]}" \
	-e KEYNAME="$keyname" -e CHECKSUM="$checksum" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	"$image" sh -euc '
	apk -q add alpine-sdk ccache >/dev/null
	# abuild runs as root (-F): under qemu-user without the binfmt C flag, abuild-sudo
	# cannot become root, and the container is thrown away afterwards anyway
	mkdir -p /root/.abuild /work/gustard-r26
	cp /keys/$KEYNAME /keys/$KEYNAME.pub /root/.abuild/
	echo "PACKAGER_PRIVKEY=/root/.abuild/$KEYNAME" > /root/.abuild/abuild.conf
	echo "JOBS=$(nproc)" >> /root/.abuild/abuild.conf
	cp /keys/$KEYNAME.pub /etc/apk/keys/
	[ ! -d /ccache ] || echo "USE_CCACHE=1" >> /root/.abuild/abuild.conf
	for p in "$@"; do
		# abuild names the repository after the directory above the package: gustard-r26
		w=/work/gustard-r26/$p
		cp -r /src/$p $w
		if [ "$CHECKSUM" = true ]; then
			(cd $w && abuild -F checksum) && cp $w/APKBUILD /repo/$p.APKBUILD
		else
			# -r also installs dependencies from REPODEST, i.e. the packages built before it
			(cd $w && REPODEST=/repo abuild -F -r)
		fi
	done
	chown -R "$HOST_UID:$HOST_GID" /repo
	[ ! -d /var/cache/distfiles ] || chown -R "$HOST_UID:$HOST_GID" /var/cache/distfiles
	[ ! -d /ccache ] || chown -R "$HOST_UID:$HOST_GID" /ccache
	' sh "$@"

if $checksum; then
	for p in "$@"; do cp "$out/$p.APKBUILD" "$here/$p/APKBUILD"; done
	rm -rf /var/tmp/r26-abuild-checksum
	echo "checksums written"
else
	ls -l "$out"/gustard-r26/armv7/
fi

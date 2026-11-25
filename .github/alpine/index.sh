#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# index.sh <repo dir> <private key file> <description>: write and sign APKINDEX.tar.gz for the
# armv7 packages in <repo dir>, as abuild does it (apk index, abuild-sign), in an Alpine
# container of the host's own architecture (indexing needs no emulation).
set -euo pipefail
repo=$(realpath "$1") key=$(realpath "$2") desc=$3
here=$(cd "$(dirname "$0")/../.." && pwd)
name=r26-mainline-1cc0db58.rsa
openssl rsa -in "$key" -pubout 2>/dev/null | cmp -s - "$here/keys/$name.pub" \
	|| { echo "the signing key does not match keys/$name.pub" >&2; exit 1; }
docker run --rm --platform "linux/$(docker version -f "{{.Server.Arch}}")" -v "$repo:/repo" -v "$key:/key/$name:ro" -v "$here/keys/$name.pub:/key/$name.pub:ro" \
	-e DESC="$desc" -e NAME="$name" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" alpine:3.24 sh -euc '
	apk -q add abuild >/dev/null
	cp /key/$NAME.pub /etc/apk/keys/
	cd /repo
	rm -f APKINDEX.tar.gz
	apk index --quiet --output APKINDEX.tar.gz.new --description "$DESC" --rewrite-arch armv7 *.apk
	abuild-sign -q -k /key/$NAME -p $NAME.pub APKINDEX.tar.gz.new
	mv APKINDEX.tar.gz.new APKINDEX.tar.gz
	tar -tzf APKINDEX.tar.gz
	chown "$HOST_UID:$HOST_GID" APKINDEX.tar.gz
'

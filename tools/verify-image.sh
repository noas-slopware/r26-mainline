#!/bin/sh
# SPDX-License-Identifier: MIT
# verify-image.sh <root>: refuse an image root that carries anything personal or a way in.
#   - no SSH host keys (sshd makes them on first boot), no authorized_keys with content
#   - no Roon identity (raat-endpoint makes one on first start), no machine-id
#   - no shell histories, no resolv.conf content, root without a password hash
#   - the kernel pair U-Boot loads is there
# R26_VERIFY_DENY=<file>: one fixed string per line (your own hostnames, addresses, MACs,
# partition ids); any of them anywhere in the root fails the check. Keep that file outside
# the repository.
set -eu
R=$1
fail=0
bad() { echo "verify-image: $*" >&2; fail=1; }

for k in "$R"/etc/ssh/ssh_host_*; do [ ! -e "$k" ] || bad "SSH host key ${k#"$R"}"; done
for f in "$R"/root/.ssh/authorized_keys "$R"/home/*/.ssh/authorized_keys; do
	[ ! -s "$f" ] || bad "non-empty ${f#"$R"}"
done
[ -z "$(ls -A "$R/var/lib/raat-endpoint" 2>/dev/null)" ] || bad "/var/lib/raat-endpoint is not empty"
[ ! -e "$R/etc/machine-id" ] || bad "/etc/machine-id"
for h in "$R"/root/.ash_history "$R"/root/.bash_history "$R"/root/.python_history; do
	[ ! -e "$h" ] || bad "${h#"$R"}"
done
[ ! -s "$R/etc/resolv.conf" ] || bad "/etc/resolv.conf has content"
grep -q '^root:\*:' "$R/etc/shadow" || bad "root has a password field other than '*'"
awk -F: '$2 !~ /^[*!]/ { print $1 }' "$R/etc/shadow" | grep . && bad "accounts with a password hash"
[ -s "$R/GustardCore" ] && [ -s "$R/00" ] || bad "no /GustardCore and /00"

if [ -n "${R26_VERIFY_DENY:-}" ]; then
	while IFS= read -r s; do
		[ -n "$s" ] || continue
		if grep -rIlF -- "$s" "$R" 2>/dev/null | head -3 | grep .; then bad "a denied string is in the files above"; fi
	done < "$R26_VERIFY_DENY"
fi

[ $fail = 0 ] || exit 1
echo "verify-image: OK"

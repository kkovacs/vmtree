#!/bin/bash

# Location of file to use
FILE=/etc/caddy/nopasswd-hosts

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Store original checksum
CHECKSUM1=$(sha256sum "$FILE" | awk '{print $1}')

# Header
echo '["placeholder-httpnoauth.kr7.hu"' >"$FILE"

# Find marker file
for a in /var/snap/lxd/common/lxd/storage-pools/default/containers/*/rootfs/nopassword; do
	VM="$(echo "$a" | awk -F/ '{print $10}')";
	# Safety when no files at all
	if [ "$VM" == "*" ]; then
		break;
	fi
	echo ",\"${VM}.kr7.hu\"" >>"$FILE"
done

# Footer
echo ']' >>"$FILE"

# See current checksum
CHECKSUM2=$(sha256sum "$FILE" | awk '{print $1}')

# Was there a change in the JSON file?
if [[ "$CHECKSUM1" != "$CHECKSUM2" ]]; then
	# Commit change to Caddyserver
	lxc exec caddy -- curl -X PATCH -d @/etc/caddy/nopasswd-hosts -H "Content-Type: application/json" http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/0/handle/0/routes/0/match/0/not/0/host
fi

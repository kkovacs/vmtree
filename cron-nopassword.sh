#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env
source detect.sh

# Location of file to use
FILE=/etc/caddy/nopasswd-hosts

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Store original checksum
CHECKSUM1=$(sha256sum "$FILE" | awk '{print $1}')

# Header
echo "[\"placeholder-httpnoauth.${DOMAIN}\"" >"$FILE"

# Find marker file
for VM in $($TOOL list --format csv --columns n); do
	if $TOOL file pull "$VM/nopassword" - 2>/dev/null ; then
		echo ",\"${VM}.${DOMAIN}\"" >>"$FILE"
	fi
done

# Footer
echo ']' >>"$FILE"

# See current checksum
CHECKSUM2=$(sha256sum "$FILE" | awk '{print $1}')

# Was there a change in the JSON file?
if [[ "$CHECKSUM1" != "$CHECKSUM2" ]]; then
	# Commit change to Caddyserver
	curl -X PATCH -d @/etc/caddy/nopasswd-hosts -H "Content-Type: application/json" http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/0/handle/0/routes/0/match/0/not/0/host
fi

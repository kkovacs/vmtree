#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# One run at a time, cron or manual (overlapping "delete -f" runs collide in LXD)
exec 9>/run/vmtree-killme.lock
flock -n 9 || { echo "Another run is in progress, skipping" >&2; exit 0; }

# Source env
source .env
source detect.sh

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $($TOOL list --format csv --columns n); do
	if $TOOL file pull "$VM/killme" - 2>/dev/null ; then
		echo "Killme deleting $VM";
		$TOOL delete -f "$VM"
	fi
done

#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# One run at a time, cron or manual (an overlapping run would snapshot twice)
exec 9>/run/vmtree-snapshotme.lock
flock -n 9 || { echo "Another run is in progress, skipping" >&2; exit 0; }

# Source env
source .env
source detect.sh

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $($TOOL list --format csv --columns n); do
	if $TOOL file pull "$VM/snapshotme" - 2>/dev/null ; then
		echo "Snapshotme snapshotting $VM";
		case "$TOOL" in
			incus) $TOOL snapshot create "$VM" ;;
			lxc)   $TOOL snapshot "$VM" ;;
		esac
		# Remove file to indicate snapshot has been done
		$TOOL file delete "$VM/snapshotme" 2>/dev/null
	fi
done

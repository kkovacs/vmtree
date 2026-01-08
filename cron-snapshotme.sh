#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $($TOOL list --format csv --columns n); do
	if $TOOL file pull "$VM/snapshotme" - 2>/dev/null ; then
		echo "Snapshotme snapshotting $VM";
		$TOOL snapshot "$VM"
		# Remove file to indicate snapshot has been done
		$TOOL file delete "$VM/snapshotme" 2>/dev/null
	fi
done

#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $(incus list --format csv --columns n); do
	if incus file pull "$VM/snapshotme" - 2>/dev/null ; then
		echo "Snapshotme snapshotting $VM";
		incus snapshot "$VM"
		# Remove file to indicate snapshot has been done
		incus file delete "$VM/snapshotme" 2>/dev/null
	fi
done

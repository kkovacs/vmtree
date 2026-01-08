#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $(incus list --format csv --columns n); do
	if incus file pull "$VM/killme" - 2>/dev/null ; then
		echo "Killme deleting $VM";
		incus delete -f "$VM"
	fi
done

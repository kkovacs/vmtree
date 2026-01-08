#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

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

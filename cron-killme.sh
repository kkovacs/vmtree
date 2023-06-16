#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for VM in $(lxc list --format csv --columns n); do
	if lxc file pull "$VM/killme" - 2>/dev/null ; then
		echo "Killme deleting $VM";
		lxc delete -f "$VM"
	fi
done

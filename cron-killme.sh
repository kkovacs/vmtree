#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Find marker file
for a in /var/snap/lxd/common/lxd/storage-pools/default/containers/*/rootfs/killme; do
	VM="$(echo "$a" | awk -F/ '{print $10}')";
	# Safety so we don't kill ALL VMs when there is no "killme" file and awk returns "*"
	if [ "$VM" == "*" ]; then
		#echo "Not killing ALL"
		break;
	fi
	echo "Killme deleting $VM";
 	lxc delete -f "$VM"
done

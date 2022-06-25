#!/bin/bash

# Force location
cd "$(dirname "$0")"

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Log current state
LOGFILE=/vmtree/log/state-`date +%Y%m%d`.txt
lxc list --format csv -c nstcl46SN >$LOGFILE
free -m >>$LOGFILE
df -m | grep -v 'snap\|tmpfs\|udev' >>$LOGFILE

# Stop/kill personal VMs
for VM in $(lxc list --format csv -c n ); do
	if [[ ! -f /var/snap/lxd/common/lxd/storage-pools/default/containers/$VM/rootfs/nokill ]]; then
		# Every VM (without protection) is considered ephemeral, destroy them.
		echo "Deleting $VM" >>$LOGFILE
		lxc delete -f "$VM"
	else
		# If it is a "nokill" VM but personal, still stop it. But leave dev-VMs running.
		if [[ "${VM%-*}" == "dev" ]]; then
			echo "No-kill: $VM" >>$LOGFILE
		else
			echo "Stopping $VM" >>$LOGFILE
			lxc stop "$VM"
		fi
	fi
done

# Log once more
free -m >>$LOGFILE

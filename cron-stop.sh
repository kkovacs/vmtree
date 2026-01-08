#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Log current state
LOGFILE="/vmtree/log/state-$(date +%Y%m%d).txt"
$TOOL list --format csv -c nstcl46SN >"$LOGFILE"
free -m >>"$LOGFILE"
df -m | grep -v 'snap\|tmpfs\|udev' >>"$LOGFILE"

# Stop/kill personal VMs
for VM in $($TOOL list --format csv --columns n | grep -- -); do
	if ! $TOOL file pull "$VM/nokill" - 2>/dev/null ; then
		# Every VM (without protection) is considered ephemeral, destroy them.
		echo "Deleting $VM" >>"$LOGFILE"
		$TOOL delete -f "$VM"
	else
		# If it is a "nokill" VM but personal, still stop it. But leave demo-VMs running.
		if [[ "${VM%-*}" == "demo" ]]; then
			echo "No-kill: $VM" >>"$LOGFILE"
		else
			echo "Stopping $VM" >>"$LOGFILE"
			$TOOL stop "$VM"
		fi
	fi
done

# Log once more
free -m >>"$LOGFILE"

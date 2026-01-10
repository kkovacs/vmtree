#!/bin/bash

# This script runs the given command on all (running) $TOOL instances.
# Poor man's ansible-console. :)

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env
source detect.sh

# Sanity check
if [[ $# -lt 1 ]]; then
	printf "\nUsage:\n  $0 <command-to-exec>\n\n"
	exit 1
fi

# Cron doesn't have this in PATH
export PATH="$PATH:/snap/bin"

# Run command on all VMs
$TOOL list -c n --format csv | while read -r VM; do
	printf "\n\e[32m=== $VM ===\e[0m\n"
	$TOOL exec -n "$VM" -- /bin/bash -c 'eval "$@"' -- "$@"
done

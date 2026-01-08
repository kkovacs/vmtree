#!/bin/bash
#
# This script sets up the current server to listen as an LXD remote, which can
# be added to other LXD servers with "remote add ...".  The point is that
# you can copy containers between servers then.
#
# It's recommended to copy snapshots (not running containers):
#
#     $TOOL snapshot NAME-OF-LXD-CONTAINER
#     $TOOL copy --mode push --stateless --instance-only NAME-OF-LXD-CONTAINER/snapshot-XXXXXX-X NAME-OF-REMOTE-LXD-SERVER:
#
# If you are brave you CAN copy instances, but your instance will be "FROZEN"
# by LXD while copying:
#
#     $TOOL copy --mode push --stateless --instance-only NAME-OF-LXD-CONTAINER/snapshot-XXXXXX-X NAME-OF-REMOTE-LXD-SERVER:

# Strict mode
set -e
# Force location
cd "$(dirname "$0")" || exit
# Configuration
source .env
source detect.sh

# Incus requires a name for the trust
if [ $# -lt 1 ]; then
    printf "\nUsage: $0 <name>\n\n"
    exit 1
fi
NAME="$1"

# Open port that can be connected to
# You can disable later: $TOOL config set core.https_address ''
$TOOL config set core.https_address :8443

# Just for debug
printf "\nJust for reference, currently trusted clients:\n\n"
$TOOL config trust list
printf "\nCurrently outstanding (unused) tokens:\n\n"
$TOOL config trust list-tokens

# Generate a trust token
# NOTE: Will ask for a client name
printf "\nGenerating a new client token:\n\n"
$TOOL config trust add "$NAME"

printf "\nNow run this command on the other side, and supply the token generated (above):\n\n"
printf "$TOOL remote add --accept-certificate \"$DOMAIN\""
printf "\n\n"

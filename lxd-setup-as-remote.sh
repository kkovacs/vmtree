#!/bin/bash
#
# This script sets up the current server to listen as an LXD remote, which can
# be added to other LXD servers with "lxd remote add ...".  The point is that
# you can copy containers between servers then.
#
# It's recommended to copy snapshots (not running containers):
#
#     lxc snapshot NAME-OF-LXD-CONTAINER
#     lxc copy --mode push --stateless --instance-only NAME-OF-LXD-CONTAINER/snapshot-XXXXXX-X NAME-OF-REMOTE-LXD-SERVER:
#
# If you are brave you CAN copy instances, but your instance will be "FROZEN"
# by LXD while copying:
#
#     lxc copy --mode push --stateless --instance-only NAME-OF-LXD-CONTAINER/snapshot-XXXXXX-X NAME-OF-REMOTE-LXD-SERVER:
#
# To increase performance (because rsync seems CPU-bound), it's recommended to run this too on the SOURCE machine:
#
#     lxc storage set default rsync.compression false

# Strict mode
set -e
# Force location
cd "$(dirname "$0")" || exit
# Configuration
source .env

# Open port that can be connected to
# You can disable later: lxc config set core.https_address ''
lxc config set core.https_address :8443

# Just for debug
printf "\nJust for reference, currently trusted clients:\n\n"
lxc config trust list
printf "\nCurrently outstanding (unused) tokens:\n\n"
lxc config trust list-tokens

# Generate a trust token
# NOTE: Will ask for a client name
printf "\nGenerating a new client token:\n\n"
lxc config trust add

printf "\nNow run this command on the other side, and supply the token generated (above):\n\n"
printf "lxc remote add --accept-certificate \"$DOMAIN\""
printf "\n\n"

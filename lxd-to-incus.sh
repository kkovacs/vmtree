#!/bin/bash

read -p "This tool is used to migrate an LXD-based VMTREE to Incus. Is this what you want to do? (Type 'yes'): "
if [[ $REPLY != 'yes' ]]; then
	exit
fi

########################################
# Basic script setup
########################################

# Strict mode
set -ex
# Force location
cd "$(dirname "$0")" || exit
# Load helper functions
source lib.sh

# Prevent ubuntu "restart" dialog
export DEBIAN_FRONTEND=noninteractive

# Ensure root
if [[ $EUID -ne 0 ]]; then
	echo "ERROR: Please run as root!"
	exit 1
fi

# Ensure correct host OS
source /etc/os-release
if [[ "$VERSION_ID" != "24.04" && "$VERSION_ID" != "26.04" ]]; then
	echo "ERROR: Please install on Ubuntu 24.04 or 26.04!"
	exit 1
fi

# Configuration
source .env

# If $TOOL is not yet defined, then amend .env
if [[ -z $TOOL ]]; then
	cat >>.env <<EOF

# LXD-TO-INCUS
TOOL=incus
TOOLADMIN="incus admin"
TOOLGROUP="incus-admin"
BRIDGE=lxdbr0
EOF
fi

# Configuration AGAIN
source .env

# Install Incus
if [[ ! -f /usr/bin/incus ]]; then
	until apt-get install -y incus incus-tools ; do sleep 1; done;
fi

# Unix user in the right groups - temporarily, for both tools
usermod -G lxd,incus-admin "vmtree"

# Run Incus's tool
lxd-to-incus

# Re-install VMTREE
./install.sh

# Force restart networking
sudo networkctl reload
sudo systemctl daemon-reload
sudo systemctl restart incus

#!/bin/bash

########################################
# Basic script setup
########################################

# Strict mode
set -ex
# Needed for mapfile
shopt -s lastpipe
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
if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04"  && "$VERSION_ID" != "26.04" ]]; then
	echo "ERROR: Please install on a recent Ubuntu! Your version: $VERSION_ID"
	exit 1
fi

# Check if we are at the right place.
# We are weird like that,
# but no, I'm not making anything configurable unless absolutely needed.
if [[ "$(pwd)" != "/vmtree" ]]; then
	echo "ERROR: Please move everything to the /vmtree/ directory."
	exit 1
fi

# If .env doesn't exist, initialize it
if [[ ! -f .env ]]; then
	_template templates/env .env -m 640
fi

# Configuration
source .env

# Do we know our domain already? (From the .env file, usually)
if [[ -z "$DOMAIN" ]]; then
	echo "ERROR: Please edit and fill out the /vmtree/.env file!"
	exit 1
fi

# Give an option to just do the previous checks and generate the initial .env file.
if [[ " $* " == *" --skip-install "* ]]; then
	echo "CHECKS COMPLETE: Now please edit and fill out the /vmtree/.env file, then run $0 again!"
	exit 0
fi

# Ensure /vmtree
install -o root -g root -m 755 -d /vmtree
# Ensure /vmtree/disks, but only if not using ZFS. (On ZFS, it's a mountpoint option)
if [[ -z "$ZFS_DISK" ]]; then
	install -o root -g root -m 755 -d /vmtree/disks
fi
# Ensure /vmtree/keys
install -o root -g root -m 755 -d /vmtree/keys
# Ensure /vmtree/log
install -o root -g root -m 750 -d /vmtree/log

########################################
# Caddy reverse proxy
########################################

# Set up Caddy repos
if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
	until apt-get update; do sleep 1; done
fi

# Install.
if [[ ! -f /usr/bin/caddy ]]; then
	until apt-get install -y caddy man less psmisc screen htop curl wget jq bash-completion dnsutils git tig socat rsync unzip jq vim-nox unattended-upgrades openssh-server zfsutils-linux ; do sleep 1; done;
	# For now, if Incus is not found, we go with LXD.
	# NOTE: This might change later.
	if ! type -p incus; then
		snap install --classic lxd --channel=6/stable
		# This is to prevent the LXD UI activating automatically if we ever use this
		# server as an LXD remote (see "setup-as-remote.sh")
		sudo snap set lxd ui.enable=false
	fi
fi

# Detect what we have (LXD or Incus)
source detect.sh

########################################
# Unix users
########################################

# Ensure permissions on ssh pubkeys
# (When copied, they tend to be 600, but they are public after all,
# and the vmtree-vm.sh script needs to read them.)
chmod 644 keys/* || { echo "ERROR: No ssh public keys found in the keys/ directory! Nobody could ssh into the VMs."; exit 1; }

# Create vmtree unix user
if [[ ! -d "/home/vmtree" ]]; then
	adduser --disabled-password --gecos "" "vmtree"
	usermod -G $TOOLGROUP "vmtree"
	# Ensure directory
	install -o "vmtree" -g "vmtree" -m 700 -d "/home/vmtree/.ssh"
fi
# Clear ssh pubkey file for filling up
install -o "vmtree" -g "vmtree" -m 700 /dev/null /home/vmtree/.ssh/authorized_keys

########################################
# Linux containers
########################################

# Initialize $TOOLADMIN only if not initialized
if ! $TOOL storage show default; then
	# If ZFS_DISK is defined...
	if [[ -n "$ZFS_DISK" ]]; then
		# initialize with the "zfs" storage driver
		# NOTE: Encrypted zpool example: "zpool create -O encryption=on -O keyformat=passphrase default $ZFS_DISK"
		$TOOLADMIN init --auto --storage-backend zfs --storage-create-device "$ZFS_DISK"
	else
		# or else, initialize with default (usually "dir") storage driver
		$TOOLADMIN init --auto
	fi
	# To increase performance (because rsync seems CPU-bound) if we ever "$TOOL copy ..."
	$TOOL storage set default rsync.compression false
fi

# Set up systemd-resolved,
# to be able to reach VMs by name from the host machine.
# Based on: https://linuxcontainers.org/lxd/docs/master/howto/network_bridge_resolved/
# Bridge device
BRIDGE="$($TOOL profile device get default eth0 network)"
# Get $TOOL's dnsmasq IP
DNSIP="$($TOOL network get $BRIDGE ipv4.address)"
# Strip netmask
DNSIP="${DNSIP%/*}"
# Create the systemd network file to handle DNS
_template templates/BRIDGE.network /etc/systemd/network/$BRIDGE.network

# Reload systemd networking, so the above change get applied
# XXX Ugly workaround, see https://github.com/canonical/lxd/issues/14588
if networkctl | grep $BRIDGE.*unmanaged; then
	# Restart to correctly apply network settings
	sudo networkctl reload
	# Unfortunately, restart is $TOOL dependent
	case "$TOOL" in
		incus)
			sudo systemctl daemon-reload
			sudo systemctl restart incus
			;;
		lxc)
			snap restart lxd
			;;
	esac
fi

########################################
# Creating /persist/ disks
########################################

# if on ZFS, then create a volume for "/persist" disks in that
if [[ -n "$ZFS_DISK" ]]; then
	# only if it was not created yet
	if ! mountpoint /vmtree/disks/; then
		zfs create default/vmtree_disks -o mountpoint=/vmtree/disks
	fi
fi

# Add authorized_keys to vmtree user
for user in keys/*; do
	# Load ssh key
	# Shellcheck thinks it's unused, but it's not.
	# shellcheck disable=SC2034
	mapfile -t pubkeys <"$user"
	# trim directory name
	user="${user##*/}"
	# Make disk
	DISKPATH="/vmtree/disks/${user}"
	install -o 1001000 -g 1001000 -d "$DISKPATH"
	# Add restricted key(s)
	for pubkey in "${pubkeys[@]}"; do
		echo "command=\"/vmtree/vmtree-vm.sh $user \$SSH_ORIGINAL_COMMAND\" $pubkey" >>/home/vmtree/.ssh/authorized_keys
	done
done

########################################
# Configuring auto snapshots
########################################

# Should only do on ZFS, snapshots are too expensice on "dir" storage backend
if [[ -n "$ZFS_DISK" && -n "$SNAPSHOT_EXPIRY" ]]; then
	$TOOL profile set default snapshots.expiry "${SNAPSHOT_EXPIRY:-7d}"
	$TOOL profile set default snapshots.schedule "15 4 * * *" # A few minutes BEFORE cron-stop.sh (see below)
	$TOOL profile set default snapshots.pattern 'snapshot-{{creation_date.Format("20060102")}}-%d' # Golang date format
fi

########################################
# Certificates - acme.sh
########################################

# Set up acme.sh to prpoure wildcard tls,
# except if using a self-signed certificate.
if [[ "$ACME_DNS" != "selfsigned" ]]; then
	# NOTE: I'm not happy that it installs under /root,
	# but it's buggy otherwise as of 2022-06-25.
	# Install acme.sh
	if [[ ! -f /root/.acme.sh/acme.sh ]]; then
		# We don't need cron, we will do that ourselves, because we need other functionality
		curl https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online --nocron -m "dnsadmin@$DOMAIN"
	fi
	# Provision certificate if not set up yet
	# (Settings come from .env)
	if ! compgen -G /root/.acme.sh/"$DOMAIN"*/fullchain.cer; then
		/root/.acme.sh/acme.sh --issue --server letsencrypt --dns "$ACME_DNS" -d "$DOMAIN" -d "*.$DOMAIN"
	fi
	# Run cron script manually,
	# this deploys acme.sh certs to Caddy
	/vmtree/cron-renew.sh
fi

# Configure Caddy
if [[ -f templates/Caddyfile.local ]]; then
	caddyfile_local=$(<templates/Caddyfile.local)
fi
_template templates/Caddyfile /etc/caddy/Caddyfile -o root -g root -m 644

# Restart/reload caddy
systemctl reload-or-restart caddy

########################################
# Systemctl, crontab
########################################

# Protect .env file a bit better
chown root:vmtree /vmtree/.env
chmod 640 /vmtree/.env

# Set up sysctl for lots of dockers
cat >/etc/sysctl.d/99-vmtree.conf <<EOF
kernel.keys.root_maxkeys=1000000
kernel.keys.root_maxbytes=100000000
kernel.keys.maxkeys=100000
kernel.keys.maxbytes=250000000
fs.inotify.max_user_instances=10240
fs.inotify.max_user_watches=655360
EOF
# Reload sysctl
sysctl -p

# Set up crontab
# Leave this to last,
# so "every minute" scripts dont' run before things are set up,
# causing unnecessary errors.
crontab <<EOF
30 4 * * * /vmtree/cron-stop.sh >/dev/null 2>&1
* * * * * /vmtree/cron-killme.sh >/dev/null 2>&1
* * * * * /vmtree/cron-snapshotme.sh >/dev/null 2>&1
* * * * * /vmtree/cron-nopassword.sh >/dev/null 2>&1
$([[ $ACME_DNS == "selfsigned" ]] && echo "#")9 0 * * * /vmtree/cron-renew.sh
EOF

# Success
printf "\nSUCCESS! vmtree had been set up!\n"
cat <<EOF

You can reach VMs' port 80 at: https://my-vmname.$DOMAIN/
With HTTP username/password: $AUTHUSER / $AUTHPASS

Now put this in your .ssh/config:

Host *.${DOMAIN}
        User user
        ProxyCommand ssh vmtree@${DOMAIN} "%h"
        UserKnownHostsFile /dev/null
        StrictHostKeyChecking no
        ForwardAgent yes

Then just:
ssh my-vmname.${DOMAIN}
EOF

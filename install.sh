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

# Ensure root
if [[ $EUID -ne 0 ]]; then
	echo "ERROR: Please run as root!"
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
	_template templates/env .env -m 644
fi

# Configuration
source .env

# Do we know our domain already? (From the .env file, usually)
if [[ -z "$DOMAIN" ]]; then
	echo "ERROR: Please edit and fill out the /vmtree/.env file!"
	exit 1
fi

# Ensure /vmtree
install -o root -g root -m 755 -d /vmtree
# Ensure /vmtree/disks
install -o root -g root -m 755 -d /vmtree/disks
# Ensure /vmtree/keys
install -o root -g root -m 755 -d /vmtree/keys
# Ensure /vmtree/log
install -o root -g root -m 750 -d /vmtree/log

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
	usermod -G lxd "vmtree"
	# Ensure directory
	install -o "vmtree" -g "vmtree" -m 700 -d "/home/vmtree/.ssh"
fi
# Clear ssh pubkey file for filling up
install -o "vmtree" -g "vmtree" -m 700 /dev/null /home/vmtree/.ssh/authorized_keys
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
# Caddy reverse proxy
########################################

# Set up Caddy repos
if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
	until apt-get update; do sleep 1; done
fi

# Install
if [[ ! -f /usr/bin/caddy ]]; then
	until apt-get install -y caddy less man less psmisc screen htop curl wget bash-completion dnsutils git tig socat rsync zip unzip vim-nox unattended-upgrades snapd openssh-server; do sleep 1; done;
fi

########################################
# LXD Linux containers
########################################

# Install LXD
snap install --classic lxd
lxd init --auto

# Set up systemd-resolved,
# to be able to reach VMs by name from the host machine.
# Based on: https://linuxcontainers.org/lxd/docs/master/howto/network_bridge_resolved/
# Get lxd's dnsmasq IP
DNSIP="$(lxc network get lxdbr0 ipv4.address)"
# Strip netmask
DNSIP="${DNSIP%/*}"
# Create the service file
_template templates/lxd-dns-lxdbr0.service /etc/systemd/system/lxd-dns-lxdbr0.service
# Make systemd learn about our new service
sudo systemctl daemon-reload
# Start the service, now and forever
sudo systemctl enable --now lxd-dns-lxdbr0

########################################
# Certificates - acme.sh
########################################

# Set up acme.sh to prpoure wildcard tls.
# NOTE: I'm not happy that it installs under /root,
# but it's buggy otherwise as of 2022-06-25.
# Install acme.sh
if [[ ! -f /root/.acme.sh/acme.sh ]]; then
	# We don't need cron, we will do that ourselves, because we need other functionality
	curl https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online --nocron -m "dnsadmin@$DOMAIN"
fi
# Provision certificate if not set up yet
# (Settings come from .env)
if [[ ! -f "/root/.acme.sh/$DOMAIN/fullchain.cer" ]]; then
	/root/.acme.sh/acme.sh --issue --dns "$ACME_DNS" -d "$DOMAIN" -d "*.$DOMAIN"
fi
# Run cron script manually,
# this deploys acme.sh certs to Caddy
/vmtree/cron-renew.sh

# Configure Caddy
_template templates/Caddyfile /etc/caddy/Caddyfile -o root -g root -m 644

# Restart/reload caddy
systemctl reload-or-restart caddy

########################################
# Systemctl, crontab
########################################

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
crontab <<"EOF"
0 6 * * * /vmtree/cron-stop.sh >/dev/null 2>&1
* * * * * /vmtree/cron-killme.sh >/dev/null 2>&1
* * * * * /vmtree/cron-nopassword.sh >/dev/null 2>&1
9 0 * * * /vmtree/cron-renew.sh
EOF

# Success
printf "\nSUCCESS! vmtree had been set up!"
cat <<EOF
Now put this in your .ssh/config:

Host *.wp1.pw
        User user
        ProxyCommand ssh vmtree@${DOMAIN} "%h"
        UserKnownHostsFile /dev/null
        StrictHostKeyChecking no
        ForwardAgent yes
EOF

#!/bin/bash

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
	echo "Please run as root!"
	exit 1
fi

# Check if we are at the right place.
# We are weird like that,
# but no, I'm not making anything configurable unless absolutely needed.
if [[ "$(pwd)" != "/vmtree" ]]; then
	echo "Please move everything to the /vmtree/ directory."
	exit 1
fi

# If .env doesn't exist, initialize it
if [[ ! -f .env ]]; then
	_template templates/env .env
fi

# Configuration
source .env

# Do we know our domain already? (From the .env file, usually)
if [[ -z "$DOMAIN" ]]; then
	echo "Please edit and fill out the .env file!"
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

# Set up Caddy repos
if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
	until apt-get update; do sleep 1; done
fi

# Install
if [[ ! -f /usr/bin/caddy ]]; then
	until apt-get install -y caddy less man less psmisc screen htop curl wget bash-completion dnsutils git tig socat rsync zip unzip vim-nox unattended-upgrades; do sleep 1; done;
fi

# Install LXD
snap install --classic lxd
lxd init --auto

# Configure Caddy
_template templates/Caddyfile /etc/caddy/Caddyfile -o root -g root -m 644

# Restart/reload caddy
systemctl reload-or-restart caddy

# Ensure permissions on ssh pubkeys
# (When copied, they tend to be 600, but they are public after all,
# and the vmtree-vm.sh script needs to read them.)
chmod 644 keys/*

# Create users with authorized_keys
for user in keys/*; do
	# Sanity check: are there any ssh keys?
	if [[ "$user" == "keys/*" ]]; then
		echo "ERROR: No ssh public keys found in the keys/ directory! Nobody could ssh into the VMs."
		exit 1
	fi
	# Load ssh key
	# Shellcheck thinks it's unused, but it's not.
	# shellcheck disable=SC2034
	mapfile -t pubkeys <"$user"
	# trim directory name
	user="${user##*/}"
	if [[ ! -d "/home/${user}" ]]; then
		adduser --disabled-password --gecos "" "${user}"
		usermod -G lxd "${user}"
	fi
	# Make disk
	DISKPATH="/vmtree/disks/${user}"
	install -o 1001000 -g 1001000 -d "$DISKPATH"
	# Set up restricted key
	install -o "${user}" -g "${user}" -m 700 -d "/home/${user}/.ssh"
	_template  "templates/authorized_keys" "/home/${user}/.ssh/authorized_keys" -o "${user}" -g "${user}" -m 600
done

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

# Set up acme.sh to prpcure wildcard tls.
# NOTE: I'm not happy that it installs under /root,
# but it's buggy otherwise as of 2022-06-25.
if [[ ! -f /root/.acme.sh/acme.sh ]]; then
	# We don't need cron, we will do that ourselves, because we need other functionality
	curl https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online --nocron -m "dnsadmin@$DOMAIN"
fi

# Settings come from .env
/root/.acme.sh/acme.sh --issue --dns "$ACME_DNS" -d "$DOMAIN" -d "*.$DOMAIN"

# Set up crontab
crontab <<"EOF"
0 6 * * * /vmtree/cron-stop.sh >/dev/null 2>&1
* * * * * /vmtree/cron-killme.sh >/dev/null 2>&1
* * * * * /vmtree/cron-nopassword.sh >/dev/null 2>&1
9 0 * * * /vmtree/cron-renew.sh
EOF

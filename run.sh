#!/bin/bash

# Strict mode
set -ex
# Needed for mapfile
shopt -s lastpipe
# Force location
cd "$(dirname "$0")"
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

	## XXX for dev
	#echo "I'll do it for you."
	#find . -path "./.git" -prune -o -type d -exec bash -c "install -o root -g root -d \"/vmtree/{}\"" \;
	#find . -path "./.git" -prune -o -type f -exec bash -c "ln -s \"$(pwd)/{}\" /vmtree/{}" \;
	#ln -s "$(pwd)/.git" /vmtree/.git
	exit 1
fi

# Configuration
source .env || true
domain="kr7.hu"

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
_template Caddyfile.template /etc/caddy/Caddyfile -o root -g root -m 644

# Restart/reload caddy
systemctl reload-or-restart caddy

# Create users with authorized_keys
# XXX Error if no keys at all
for user in keys/*; do
	# Load ssh key
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
	_template  "authorized_keys.template" "/home/${user}/.ssh/authorized_keys" -o "${user}" -g "${user}" -m 600
done

# XXX Set up acme.sh

# Set up crontab
crontab <<"EOF"
0 6 * * * /vmtree/cron-stop.sh >/dev/null 2>&1
* * * * * /vmtree/cron-killme.sh >/dev/null 2>&1
* * * * * /vmtree/cron-nopassword.sh >/dev/null 2>&1
9 0 * * * /vmtree/cron-renew.sh
EOF

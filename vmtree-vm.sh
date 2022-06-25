#!/bin/bash

# Needed for mapfile and advanced pattern matching
shopt -s lastpipe extglob

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Strip VM name of domain, then split on "-"
# Shellcheck thinks we don't want splitting, but we do.
# shellcheck disable=SC2206
IFS="-" PARTS=( ${1%%.*} )

# Sanity check
if [[ ${#PARTS[@]} -lt 2 ]]; then
	echo "Please use the format: user-vmname" >&2
	exit 1
fi

# Friendlier variable
REQUSER="${PARTS[0]}"
REQVM="${PARTS[1]}"
REQIMAGE="${PARTS[2]:-ubuntu2204}"
REQETC="${PARTS[3]}"
# Force "prefix-" to VM, but let anyone use "dev"
if [[ "$REQUSER" == "dev" ]]; then
	# Set USER
	USER="dev"
	# Load ALL keys
	cat /vmtree/keys/* | mapfile -t PUBKEYS
else
	# Load ONLY USER's key
	mapfile -t PUBKEYS <"/vmtree/keys/$USER"
fi
DISK="$USER"
VM="$USER-$REQVM"
DISKPATH="/vmtree/disks/$DISK"

echo "Just FYI - you have the following VMs here:" >&2
lxc list -c nst4,image.release,mcl "^${USER}-" >&2

# Images
declare -A images
# Best:
images["ubuntu2004"]="ubuntu:20.04"                  # Works 100%
images["ubuntu2204"]="ubuntu:22.04"                  # Works 100%
# Others:
images["alma8"]="images:almalinux/8/cloud"         # Works, not thoroughly tested
images["alma9"]="images:almalinux/9/cloud"         # Works, not thoroughly tested
images["centos8"]="images:centos/8-Stream/cloud"   # Works, not thoroughly tested
images["centos9"]="images:centos/9-Stream/cloud"   # Works, not thoroughly tested
images["debian11"]="images:debian/11/cloud"        # First connect never works, SSH install takes time
images["debian12"]="images:debian/12/cloud"        # First connect never works, SSH install takes time
images["rocky8"]="images:rockylinux/8/cloud"       # Works, not thoroughly tested
# Tested NOT working:
#images["centos7"]="images:centos/7/cloud"         # "requires a CGroupV1 host system"
#images["alpine"]="images:alpine/edge/cloud"       # No SSH running
echo -e "Available images (user-vmname-IMAGE): ${!images[@]}" >&2
IMAGE="${images[$REQIMAGE]:-ubuntu:22.04}"

# Show info
echo "You are getting VM=$VM IMAGE=$IMAGE" >&2

# Default lxc options
OPTS=("-c" "security.nesting=true" "-c" "linux.kernel_modules=overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan")

# REAL VM (as opposed to container) mode
# XXX EXPERIMENTAL!
# XXX No way to "killme" it, no way to "nokill" it, no way to "nopassword", etc
if [[ "$REQETC" == "vm" ]]; then
	# This changes EVERYTHING (in OPTS)
	OPTS=( "--vm" )
	# Set REAL VMs ephemeral for now, as an alternative way to kill it on demand.
	OPTS+=( "-e" )
fi

# Print infos here.
# Maybe it gets read while the user is waiting.
cat >&2 <<"EOF"

====================================== N E W S ======================================
On this new VMTREE, some things are different from the old one:
- All VMs die at night by DEFAULT. Even "dev-xxx" VMs.
- BUT! YOU CAN make any VM survive the night by running: "sudo touch /nokill"
  - "nokill"-ed "dev-xxx" VMs will keep running (don't power down).
  - "nokill"-ed "personal" VMs will POWER DOWN at night, but DON'T get deleted.
- Running "sudo poweroff" to destroy a VM doesn't work anymore. Use "sudo touch /killme"
=====================================================================================

EOF

# Does the VM exists?
if ! lxc info "$VM" >/dev/null 2>&1 ; then
	# launch docker-capable vm
	echo "Initializing" >&2
	lxc init "${IMAGE}" "$VM" "${OPTS[@]}" >&2 </dev/null
	# Mount disk if exists
	if [[ -d "$DISKPATH" ]]; then
		echo "Attaching disks/$DISK" >&2
		lxc config device add "$VM" "$DISK" disk "source=$DISKPATH" "path=/persist" >&2
	fi
	echo "Cloud-config" >&2
	# Apply cloud-config
	lxc config set "$VM" user.user-data - >&2 <<EOF
#cloud-config
users:
- name: user
  ssh_authorized_keys:
$(for pubkey in "${PUBKEYS[@]}"; do echo "  - ${pubkey}"; done)
  shell: /bin/bash
  sudo: "ALL=(ALL) NOPASSWD:ALL"
package_update: true
packages:
- bash-completion
- curl
- dnsutils
- git
- htop
- less
- openssh-server
- psmisc
- rsync
- screen
- socat
- tig
- unattended-upgrades
- unzip
- vim-nox
- wget
- zip
write_files:
- path: /etc/motd
  content: |
    ================== Mini-HOWTO ==================
    Destroy this VM: ..................... sudo touch /killme
    Make this VM survive the night: ...... sudo touch /nokill
    Disable HTTP password protection: .... sudo touch /nopassword
    ================================================
#- path: /etc/docker/daemon.json
#  content: |
#    { "storage-driver": "overlay2" }
- path: /etc/sysctl.d/95-unprivileged-ports.conf
  content: |
    net.ipv4.ip_unprivileged_port_start=0
bootcmd:
- [ "sysctl", "-w", "net.ipv4.ip_unprivileged_port_start=0" ]
EOF

fi

echo "Starting" >&2
lxc start "$VM" >/dev/null >&2

# Wait for IP
# NOTE: The reason for the double test is that if it's an OLD vm,
# then SSH is probably already running, no need to wait even a litte.
# On the other hand, if it's a NEW vm,
# then ssh needs some time to generate keys and start.
echo -n "Getting IP" >&2
IPS="$(lxc list --format csv -c 4 "^${VM}$")"
until [[ "${#IPS}" -gt 1 ]]; do
	IPS="$(lxc list --format csv -c 4 "^${VM}$")"
	if [[ "${#IPS}" -gt 1 ]]; then
		sleep 5 # XXX Wait for SSH to start
		break;
	fi
	echo -n "." >&2
	sleep 1
done
echo " IPs: $IPS" >&2

# stdio fwd
echo "Connecting" >&2
nc "${VM}.lxd" 22

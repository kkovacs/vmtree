#!/bin/bash

# Needed for mapfile and advanced pattern matching
shopt -s lastpipe extglob

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env
source detect.sh

# Script's first parameter is ssh pubkey name (username)
SSHUSER="$1"
shift

# Strip VM name of domain, then split on "-"
# XXX Should be a better way of splitting that doesn't mess with IFS
SAVEIFS="$IFS"
# Shellcheck thinks we don't want splitting, but we do.
# shellcheck disable=SC2206
IFS="-" PARTS=( ${1%%.*} )
IFS="$SAVEIFS"
unset SAVEIFS

# One word vmname or more?
if [[ ${#PARTS[@]} -eq 1 ]]; then
	# One word vm name is a special case. We never try to launch it, just connect -- if the SSH key is in.
	# One useful way to create one-word VMs is by starting them as `demo-vmname`, then using `$TOOL rename`.
	REQUSER=""
	REQVM="${PARTS[0]}"
	REQIMAGE="${DEFAULTIMAGE:-ubuntu2404}"
	REQETC=""
	VM="$REQVM"
	DISKPATH="/dev/null" # Won't count since we never launch, but anyway
	printf "Trying to connect you directly to \"$REQVM\"...\n\n" >&2
else
	# Friendlier variable
	REQUSER="${PARTS[0]}"
	REQVM="${PARTS[1]}"
	REQIMAGE="${PARTS[2]:-${DEFAULTIMAGE:-ubuntu2404}}"
	REQETC="${PARTS[3]}"
	# Force "prefix-" to VM, but let anyone use "demo"
	if [[ "$REQUSER" == "demo" ]]; then
		# Load ALL keys
		cat /vmtree/keys/* | mapfile -t PUBKEYS
		# Force DISK to "demo"
		DISK="demo"
	else
		# Load ONLY SSHUSER's key(s)
		mapfile -t PUBKEYS <"/vmtree/keys/$SSHUSER"
		DISK="$SSHUSER"
	fi
	# Build final physical variables
	VM="$REQUSER-$REQVM"
	DISKPATH="/vmtree/disks/$DISK"

	echo "Just FYI - you have the following VMs here:" >&2
	$TOOL list -c nst4,image.release,mcl "^${REQUSER}-" >&2
fi

# Images
declare -A images
# Best (Works 100%):
case "$TOOL" in
	incus)
		images["ubuntu2404"]="images:ubuntu/noble/cloud"
		images["ubuntu2204"]="images:ubuntu/jammy/cloud"
		;;
	lxc)
		images["ubuntu2404"]="ubuntu:22.04"
		images["ubuntu2204"]="ubuntu:24.04"
	;;
esac
# Others:
images["alma8"]="images:almalinux/8/cloud"         # Works, not thoroughly tested
images["alma9"]="images:almalinux/9/cloud"         # Works, not thoroughly tested
images["centos8"]="images:centos/8-Stream/cloud"   # Works, not thoroughly tested
images["centos9"]="images:centos/9-Stream/cloud"   # Works, not thoroughly tested
images["debian11"]="images:debian/11/cloud"        # First connect never works, SSH install takes time
images["debian12"]="images:debian/12/cloud"        # First connect never works, SSH install takes time
images["debian13"]="images:debian/13/cloud"        # Works, not thoroughly tested
images["rocky8"]="images:rockylinux/8/cloud"       # Works, not thoroughly tested
images["rocky9"]="images:rockylinux/9/cloud"       # Works, not thoroughly tested
images["suse"]="images:opensuse/tumbleweed/cloud"  # Works, not thoroughly tested
images["suse155"]="images:opensuse/15.6/cloud"     # Works, not thoroughly tested. Unfortunately there is no plain "15", so minor version will need to be updated
images["oracle8"]="images:oracle/8/cloud"          # Works, not thoroughly tested
images["oracle9"]="images:oracle/9/cloud"          # Works, not thoroughly tested
# Tested NOT working:
#images["alpine"]="images:alpine/edge/cloud"       # Needs manual enable of user account and shell change
#images["arch"]="images:archlinux"                 # Needs "pacman -S openssh && systemctl enable --now sshd", add ssh key, then ssh to root@... works
#images["centos7"]="images:centos/7/cloud"         # "requires a CGroupV1 host system"
#images["oracle7"]="images:oracle/7/cloud"         # "requires a CGroupV1 host system"
echo -e "Available images (user-vmname-IMAGE): ${!images[*]}" >&2
IMAGE="${images[$REQIMAGE]}"

# Show info
printf "Connecting SSHUSER=$SSHUSER VM=$VM IMAGE=$IMAGE DISK=$DISK\n\nThis VM's port 80 is: https://$VM.$DOMAIN/ ( $AUTHUSER / $AUTHPASS )\n\n" >&2

# Default $TOOL options
OPTS=("-c" "security.nesting=true" "-c" "linux.kernel_modules=overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan")

# REAL VM (as opposed to container) mode
# XXX EXPERIMENTAL!
if [[ "$REQETC" = "vm"* ]]; then
	# This changes EVERYTHING (in OPTS)
	OPTS=( "--vm")
	# Set limits, if given. Enforce format
	LIMIT="${REQETC#vm}"
	# Allow only ONE DIGIT (and only a digit, preventing overuse and injection)
	if [[ "$LIMIT" =~ ^[0-9]$ ]]; then
		OPTS+=( "-c" "limits.cpu=2" "-c" "limits.memory=${LIMIT}GiB" )
	fi
fi

# Print infos here.
# Maybe it gets read while the user is waiting.
cat >&2 <templates/motd
echo >&2 # empty line

# Does the VM exists?
if ! $TOOL info "$VM" >/dev/null 2>&1 ; then
	# Sanity check
	if [[ "$REQUSER" != "$SSHUSER" && "$REQUSER" != "demo" ]]; then
		echo "ERROR: you can only start VMs called $SSHUSER-xxx and demo-xxx" >&2
		exit 1
	fi
	# launch docker-capable vm
	echo "Initializing" >&2
	$TOOL init "${IMAGE}" "$VM" "${OPTS[@]}" >&2 </dev/null
	# Mount disk if exists
	if [[ -d "$DISKPATH" ]]; then
		echo "Attaching disks/$DISK" >&2
		$TOOL config device add "$VM" "$DISK" disk "source=$DISKPATH" "path=/persist" >&2
	fi
	echo "Cloud-config" >&2
	# Apply cloud-config
	$TOOL config set "$VM" user.user-data - >&2 <<EOF
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
    ============================ Mini-HOWTO ============================
    Destroy this VM (~1 min): ..................... sudo touch /killme
    Disable HTTP password protection (~1 min): .... sudo touch /nopassword
    Make this VM survive the night: ............... sudo touch /nokill
    ====================================================================
#- path: /etc/docker/daemon.json
#  content: |
#    { "storage-driver": "overlay2" }
- path: /etc/sysctl.d/95-unprivileged-ports.conf
  content: |
    net.ipv4.ip_unprivileged_port_start=0
# XXX Next 3 lines are part of the workaround for https://github.com/canonical/lxd/issues/13389
- path: /etc/apparmor.d/local/runc
  content: |
    pivot_root,
bootcmd:
- [ "sysctl", "-w", "net.ipv4.ip_unprivileged_port_start=0" ]
runcmd:
# XXX Next 1 line is part of the workaround for https://github.com/canonical/lxd/issues/13389
- [ "systemctl", "reload", "apparmor.service" ]
EOF

fi

echo "Starting" >&2
$TOOL start "$VM" >/dev/null >&2

# Waiting for IP, for SSH port to open, and for '/run/nologin' to go away
echo -n "Waiting for ready" >&2
until (echo >"/dev/tcp/$VM.$LOCALDOMAIN/22") 2>/dev/null && ! $TOOL file pull "$VM/run/nologin" - >/dev/null 2>/dev/null; do
        echo -n "." >&2
        sleep 1
done

# Display IP
IPS="$($TOOL list --format csv -c 4 "^${VM}$")"
echo " IPs: $IPS" >&2

# stdio fwd
echo "Connecting" >&2
nc "${VM}.$LOCALDOMAIN" 22

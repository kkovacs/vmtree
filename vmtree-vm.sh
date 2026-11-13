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

# The requested VM name comes from the client, so read it from the environment
# (instead of having sshd's shell expand it unquoted on the command line,
# which would word-split and glob it). Strip domain, then validate strictly.
VMREQ="${SSH_ORIGINAL_COMMAND%%.*}"
if [[ ! "$VMREQ" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]]; then
	echo "ERROR: invalid VM name" >&2
	exit 1
fi

# Split on "-" (read -a does no globbing)
IFS="-" read -ra PARTS <<<"$VMREQ"

# One word vmname or more?
if [[ ${#PARTS[@]} -eq 1 ]]; then
	# One word vm name is a special case. We never try to launch it, just connect -- if the SSH key is in.
	# One useful way to create one-word VMs is by starting them as `demo-vmname`, then using `$TOOL rename`.
	REQUSER=""
	REQVM="${PARTS[0]}"
	REQIMAGE="${DEFAULTIMAGE:-ubuntu2604}"
	REQETC=""
	VM="$REQVM"
	DISKPATH="/dev/null" # Won't count since we never launch, but anyway
	printf "Trying to connect you directly to \"$REQVM\"...\n\n" >&2
else
	# Friendlier variable
	REQUSER="${PARTS[0]}"
	REQVM="${PARTS[1]}"
	REQIMAGE="${PARTS[2]:-${DEFAULTIMAGE:-ubuntu2604}}"
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
		images["ubuntu2604"]="images:ubuntu/resolute/cloud"
		images["ubuntu2404"]="images:ubuntu/noble/cloud"
		images["ubuntu2204"]="images:ubuntu/jammy/cloud"
		;;
	lxc)
		# XXX The only reason we use minimal-daily is because it gets the most frequent updates, which is important for security.
		images["ubuntu2610"]="ubuntu-minimal-daily:26.10"
		images["ubuntu2604"]="ubuntu-minimal-daily:26.04"
		images["ubuntu2404"]="ubuntu-minimal-daily:24.04"
		images["ubuntu2204"]="ubuntu-minimal-daily:22.04"
	;;
esac
# Others:
images["alma8"]="images:almalinux/8/cloud"         # Works, not thoroughly tested
images["alma9"]="images:almalinux/9/cloud"         # Works, not thoroughly tested
images["alma10"]="images:almalinux/10/cloud"       # New, not tested yet
images["centos9"]="images:centos/9-Stream/cloud"   # Works, not thoroughly tested
images["centos10"]="images:centos/10-Stream/cloud" # New, not tested yet
images["debian11"]="images:debian/11/cloud"        # First connect never works, SSH install takes time
images["debian12"]="images:debian/12/cloud"        # First connect never works, SSH install takes time
images["debian13"]="images:debian/13/cloud"        # Works, not thoroughly tested
images["rocky8"]="images:rockylinux/8/cloud"       # Works, not thoroughly tested
images["rocky9"]="images:rockylinux/9/cloud"       # Works, not thoroughly tested
images["rocky10"]="images:rockylinux/10/cloud"     # New, not tested yet
images["suse"]="images:opensuse/tumbleweed/cloud"  # Works, not thoroughly tested
images["suse16"]="images:opensuse/16.1/cloud"      # New, not tested yet. No plain "16", so minor version will need updating again
images["oracle8"]="images:oracle/8/cloud"          # Works, not thoroughly tested
images["oracle9"]="images:oracle/9/cloud"          # Works, not thoroughly tested
images["oracle10"]="images:oracle/10/cloud"        # New, not tested yet
# Tested NOT working:
#images["alpine"]="images:alpine/edge/cloud"       # Needs manual enable of user account and shell change
#images["arch"]="images:archlinux"                 # Needs "pacman -S openssh && systemctl enable --now sshd", add ssh key, then ssh to root@... works
#images["centos7"]="images:centos/7/cloud"         # "requires a CGroupV1 host system"
#images["oracle7"]="images:oracle/7/cloud"         # "requires a CGroupV1 host system"
echo -e "Available images (user-vmname-IMAGE): ${!images[*]}" >&2
IMAGE="${images[$REQIMAGE]}"
# Fail fast: an unknown image name would otherwise reach "$TOOL init" as ""
if [[ -z "$IMAGE" ]]; then
	echo "ERROR: unknown image \"$REQIMAGE\"" >&2
	exit 1
fi

# Show info
printf "Connecting SSHUSER=$SSHUSER VM=$VM IMAGE=$IMAGE DISK=$DISK\n\nThis VM's port 80 is: https://$VM.$DOMAIN/ ( $AUTHUSER / $AUTHPASS )\n\n" >&2

# Default $TOOL options
OPTS=("-c" "security.nesting=true" "-c" "linux.kernel_modules=overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan")

# REAL VM (as opposed to container) mode
# XXX EXPERIMENTAL!
if [[ "$REQETC" = "vm"* ]]; then
	# This changes EVERYTHING (in OPTS)
	OPTS=( "--vm")
	# Shift VM user uid to match container subuid mapping (host uid 1001000)
	IS_VM=1
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
	$TOOL init "${IMAGE}" "$VM" "${OPTS[@]}" >&2 </dev/null || exit 1
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
  ${IS_VM:+uid: 1001000}
  ssh_authorized_keys:
$(for pubkey in "${PUBKEYS[@]}"; do echo "  - ${pubkey}"; done)
  shell: /bin/bash
  sudo: "ALL=(ALL) NOPASSWD:ALL"
package_update: true
packages:
- bash-completion
- curl
- bind9-dnsutils
- git
- gron
- htop
- iputils-ping
- jq
- less
- man-db
- openssh-server
- psmisc
- rsync
- screen
- socat
- sudo
- tig
- tmux
- unattended-upgrades
- unzip
- util-linux-extra
- vim-nox
- wget
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
# Auto-upgrade security-related
- [ "unattended-upgrade", "-v" ]
# If /persist/autoexec.sh exist, run it with user permissions
- "if [ -x /persist/autoexec.sh ] ; then su - user -s /bin/bash -c /persist/autoexec.sh ; fi"
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

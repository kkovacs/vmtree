#!/bin/bash

# Needed for mapfile and advanced pattern matching
shopt -s lastpipe extglob

# Force location
cd "$(dirname "$0")"

# Strip VM name of domain, then split on "-"
IFS="-" PARTS=( ${1%%.*} )

# Sanity check
if [[ ${#PARTS[@]} -lt 2 ]]; then
	exit 1
fi

# Friendlier variable
OWNER="${PARTS[0]}"
VM="${PARTS[1]}"
# Force "prefix-" to VM, but let anyone use "dev"
if [[ "$OWNER" == "dev" ]]; then
	# Set USER
	USER="dev"
	# Load ALL keys
	cat /vmtree/keys/* | mapfile -t pubkeys
else
	# Load ONLY USER's key
	mapfile -t pubkeys <"/vmtree/keys/$USER"
fi
DISK="$USER"
VM="$USER-$VM"
DISKPATH="/vmtree/disks/$DISK"

echo "Just FYI - you have the following VMs:" >&2
lxc list -c nst4mclN "${USER}-" >&2

# Show info
echo "You requested VM=$VM" >&2

# Does the VM exists?
if ! lxc info "$VM" >/dev/null 2>&1 ; then
	# launch docker-capable vm
	echo "Initializing" >&2
	lxc init ubuntu:20.04 "$VM" "${OPTS[@]}" -c security.nesting=true -c linux.kernel_modules=overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan >&2 </dev/null
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
$(for pubkey in "${pubkeys[@]}"; do echo "  - ${pubkey}"; done)
  shell: /bin/bash
  sudo: "ALL=(ALL) NOPASSWD:ALL"
package_update: true
packages:
- less
- psmisc
- screen
- htop
- curl
- wget
- bash-completion
- dnsutils
- git
- tig
- socat
- rsync
- vim-nox
- zip
- unzip
- unattended-upgrades
write_files:
- path: /etc/motd
  content: |
    ======== Mini-HOWTO ========
    Destroy this VM: ..................... sudo touch /killme
    Make this VM survive the night: ...... sudo touch /nokill
    Disable HTTP password protection: .... sudo touch /nopassword
    ============================
- path: /etc/docker/daemon.json
  content: |
    { "storage-driver": "overlay2" }
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
echo -n "Getting IP" >&2
IP="$(lxc info "$VM" | grep "inet[^6].*global" | awk '{print $2}')"
until [[ "${#IP}" -gt 0 ]]; do
	# Get IP of VM
	IP="$(lxc info "$VM" | grep "inet[^6].*global" | awk '{print $2}')"
	if [[ "${#IP}" -gt 0 ]]; then
		sleep 5 # XXX Wait for SSH to start
		break;
	fi
	echo -n "." >&2
	sleep 1
done
# Strip netmask
IP=${IP%/*}
echo ": $IP" >&2

# Mini-howto
cat >&2 <<EOF

==================== NEWS ====================
On this new VMTREE, some things are different from the old one:
- All VMs are ephemeral (die at night) by default. Even dev-xxx VMs.
- BUT, you CAN make ANY VM not-ephemeral (survive the night) by: "sudo touch /nokill"
- If "nokill"-ed, dev-xxx VMs stay running. Personal ones still power down at night, as usual.
- Using "sudo poweroff" to destroy a VM doesn't work anymore. Use "sudo touch /killme"
==============================================

EOF

# stdio fwd
echo "Connecting" >&2
nc "$IP" 22

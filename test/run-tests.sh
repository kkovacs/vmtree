#!/bin/bash
# run-matrix.sh — Test vmtree on one OS/tool combination
# Usage:
#   OS=26 TECH=lxd test/run-matrix.sh              # run all
#   OS=26 TECH=lxd test/run-matrix.sh test_create_vm test_vm_ping  # named tests
#
# Droplet is reused across runs; never auto-destroyed.

set -exuo pipefail

# Fancy logs
export PS4=$'+\t$(date -Iseconds) L$LINENO:\t '

cd "$(dirname "$0")/.."
# -- config --
OS="${OS:-26}"
TECH="${TECH:-lxd}"
VM="${VM:-}"  # non-empty: create VMs (1GB) instead of containers
DROPLET="${DROPLET:-vmtree-test}"
REGION="${REGION:-ams3}"
SIZE="${SIZE:-s-2vcpu-2gb}"  # VM=1 needs s-4vcpu-8gb+ (3 VMs ~2.5GB)
SSH_KEY="${SSH_KEY:-./test/id_ed25519}"
IMAGE="${IMAGE:-ubuntu-${OS}-04-x64}"
if [[ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
  echo "ERROR: requires \$DIGITALOCEAN_ACCESS_TOKEN"
  exit 1
fi
case "$TECH" in
  incus) TOOL=incus ;;
  lxd)   TOOL=lxc ;;
esac
VM_SUFFIX="${VM:+-ubuntu${OS}04-vm${VM}}"  # appended to ssh_lxd hostnames for VM mode

# -- helpers --
get_ip() { doctl compute droplet list --format=PublicIPv4 --no-header "$DROPLET"; }
get_id() { doctl compute droplet list --format=ID --no-header "$DROPLET"; }

SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
  -o ConnectTimeout=10 -o LogLevel=ERROR -o IdentitiesOnly=yes
  -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY"
)

ssh_host() {
  local ip; ip=$(get_ip)
  local rc=0
  timeout 600 ssh "${SSH_OPTS[@]}" "root@$ip" "$@" || rc=$?
  if [[ $rc -eq 255 || $rc -eq 124 ]]; then
    sleep 2
    timeout 600 ssh "${SSH_OPTS[@]}" "root@$ip" "$@"
  else
    return $rc
  fi
}

ssh_lxd() {
  local d="$DOMAIN"
  local sc=(ssh
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
    -o ConnectTimeout=120 -o LogLevel=ERROR
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2
    -o "ProxyCommand=ssh ${SSH_OPTS[*]} vmtree@${d} %h"
    -i "$SSH_KEY")
  local a=0 rc=0
  while (( a < 4 )); do
    if timeout 120 "${sc[@]}" "$@" >/dev/null 2>&1; then
      timeout 180 "${sc[@]}" "$@"; return $?
    fi
    rc=$?
    [[ $rc -ne 255 && $rc -ne 124 ]] && return $rc
    ((a++))
    sleep $((2 ** a))
  done
  timeout 180 "${sc[@]}" "$@"
}

# -- setup --
setup() {
  # create droplet (or reuse existing)
  local ex
  ex=$(doctl compute droplet list --format=ID --no-header "$DROPLET" 2>/dev/null || true)
  if [[ -n "$ex" ]] && doctl compute droplet get "$ex" >/dev/null 2>&1; then
    echo "Droplet '$DROPLET' exists, reusing."
  else
    echo "Creating droplet: $DROPLET ..."
    local keys
    keys=$(doctl compute ssh-key list --format=ID --no-header | paste -sd "," -)
    doctl compute droplet create "$DROPLET" --region "$REGION" --ssh-keys "$keys" \
      --image "$IMAGE" --size "$SIZE" --wait -v
  fi

  # rebuild to target OS
  local id; id=$(get_id)
  echo "Rebuilding $id to $IMAGE ..."
  doctl compute droplet-action rebuild "$id" --image "$IMAGE" --wait >/dev/null

  # wait for SSH
  local ip; ip=$(get_ip)
  echo -n "Waiting for SSH on $ip"
  local w=0
  until ssh "${SSH_OPTS[@]}" "root@$ip" uptime >/dev/null 2>&1; do
    echo -n .; sleep 5; w=$((w+5))
    (( w > 300 )) && { echo " TIMEOUT"; return 1; }
  done
  echo " ready (${w}s)"
  DOMAIN="${ip}.nip.io"

  # install container tool
  case "$TECH" in
    incus) echo "Installing Incus..."
           ssh_host "until apt-get update -qq; do sleep 1; done; until apt-get install -y incus; do sleep 1; done" ;;
  #  lxd)   echo "Removing incus (if present) so install.sh uses LXD..."
  #         ssh_host "apt-get remove -y incus 2>/dev/null || true" ;;
  esac

  # copy test key for install.sh (must happen before rsync)
  cp "${SSH_KEY}.pub" keys/my

  # rsync code to droplet
  echo "Rsyncing vmtree..."
  rsync -a -e "ssh ${SSH_OPTS[*]}" \
    --exclude '.git' --exclude '.env' --exclude 'disks' --exclude 'log' --exclude 'id_*' \
    ./ "root@${ip}:/vmtree/"

  # zfs loop device + .env
  echo "Setting up ZFS and .env..."
  ssh_host "bash -s" <<'SETENV'
set -e; cd /vmtree
dd if=/dev/zero of=/vmtree/zfs-disk.img bs=1M count=0 seek=30720
LOOP=$(losetup -f)
losetup $LOOP /vmtree/zfs-disk.img
IP=$(curl -s ip.me)
DOMAIN="${IP}.nip.io"
cat > .env <<EOF
DOMAIN=${DOMAIN}
ACME_DNS=selfsigned
AUTHUSER=testuser
AUTHPASS=testpass
ZFS_DISK=${LOOP}
SNAPSHOT_EXPIRY=7d
EOF
SETENV

  # run install.sh
  echo "Running install.sh..."
  ssh_host "cd /vmtree && /vmtree/install.sh"

  # wait for caddy
  echo -n "Waiting for Caddy on https://placeholder-httpnoauth.${DOMAIN}"
  w=0
  until curl -sk -o /dev/null "https://placeholder-httpnoauth.${DOMAIN}" 2>/dev/null; do
    echo -n .; sleep 2; w=$((w+2))
    (( w > 60 )) && { echo " TIMEOUT"; return 1; }
  done
  echo " ready (${w}s)"
}

# -- tests --
test_caddy_active()      { ssh_host "systemctl is-active caddy"; }
test_vmtree_user()       { ssh_host "id vmtree"; }
test_storage_pool()      { ssh_host "$TOOL storage show default"; }
test_force_command()     { ssh_host "grep -q 'command=' /home/vmtree/.ssh/authorized_keys"; }

test_create_vm() {
  local out
  ssh_host "$TOOL delete -f my-test1" 2>/dev/null || true
  out=$(ssh_lxd "user@my-test1${VM_SUFFIX}.${DOMAIN}" 'echo HELLO-FROM-$(hostname)')
  [[ "$out" == *"HELLO-FROM-my-test1"* ]]
  if [[ -n "$VM" ]]; then
    ssh_host "$TOOL list --format csv -c nt | grep -q 'my-test1.*VIRTUAL-MACHINE'"
  fi
}

test_vm_running() {
  ssh_host "$TOOL list --format csv -c ns | grep -q 'my-test1.*RUNNING'"
}

test_vm_ping() {
  # host -> internet
  ssh_host "ping -c1 -W3 8.8.8.8"
  # container -> internet
  ssh_host "$TOOL exec my-test1 -- ping -c1 -W3 8.8.8.8"
  # host -> container by name
  ssh_host "ping -c1 -W3 my-test1.${TECH}"
  # container -> other container by name
  ssh_host "$TOOL delete -f my-ping2" 2>/dev/null || true
  ssh_lxd "user@my-ping2${VM_SUFFIX}.${DOMAIN}" true
  sleep 2
  ssh_host "$TOOL exec my-test1 -- ping -c1 -W3 my-ping2.${TECH}"
  ssh_host "$TOOL delete -f my-ping2" 2>/dev/null || true
}

test_caddy_proxy() {
  ssh_host "$TOOL delete -f my-web1" 2>/dev/null || true
  ssh_lxd "user@my-web1${VM_SUFFIX}.${DOMAIN}" true
  sleep 2
  ssh_host "$TOOL exec my-web1 -- bash -c \"echo hello-vmtree > /tmp/test.txt && cd /tmp && nohup python3 -m http.server 80 >/dev/null 2>&1 &\""
  sleep 2
  curl -sk -u "testuser:testpass" "https://my-web1.${DOMAIN}/test.txt" | grep -q hello-vmtree
}

test_caddy_auth_required() {
  curl -sk -o /dev/null -w '%{http_code}' "https://my-web1.${DOMAIN}/test.txt" | grep -q 401
}

test_caddy_nopassword() {
  ssh_host "$TOOL exec my-web1 -- sudo touch /nopassword"
  ssh_host 'cd /vmtree && bash cron-nopassword.sh'
  sleep 1
  curl -sk -o /dev/null -w '%{http_code}' "https://my-web1.${DOMAIN}/test.txt" | grep -q 200
}

test_persist_survives() {
  ssh_host "$TOOL delete -f my-tmp1" 2>/dev/null || true
  ssh_host "rm -f /vmtree/disks/my/test-marker"
  ssh_lxd "user@my-tmp1${VM_SUFFIX}.${DOMAIN}" "echo persisted > /persist/test-marker"
  ssh_host "grep -q persisted /vmtree/disks/my/test-marker"
  ssh_host "$TOOL delete -f my-tmp1"
  if ssh_host "$TOOL info my-tmp1 >/dev/null 2>&1"; then
    echo "VM still exists after delete!" >&2; return 1
  fi
  sleep 2
  ssh_lxd "user@my-tmp1${VM_SUFFIX}.${DOMAIN}" true
  sleep 3
  ssh_host "$TOOL exec my-tmp1 -- cat /persist/test-marker | grep -q persisted"
  ssh_host "grep -q persisted /vmtree/disks/my/test-marker"
}

test_killme() {
  ssh_host "$TOOL delete -f my-kill1" 2>/dev/null || true
  ssh_lxd "user@my-kill1${VM_SUFFIX}.${DOMAIN}" true
  sleep 3
  ssh_host "$TOOL exec my-kill1 -- sudo touch /killme"
  sleep 2
  ssh_host 'cd /vmtree && bash cron-killme.sh'
  ! ssh_host "$TOOL info my-kill1 >/dev/null 2>&1"
}

# Re-running install.sh must not disrupt existing VMs.
# We capture boot_id before/after to prove the container wasn't rebooted.
test_idempotent() {
  local boot_id
  boot_id=$(ssh_host "$TOOL exec my-test1 -- cat /proc/sys/kernel/random/boot_id")
  ssh_host 'cd /vmtree && /vmtree/install.sh'
  ssh_host "$TOOL exec my-test1 -- cat /proc/sys/kernel/random/boot_id | grep -q '$boot_id'"
}
# Touch /snapshotme inside a container, run cron-snapshotme.sh, verify snapshot
# XXX: cron-snapshotme.sh sporadically hangs on Ubuntu 26.04 (auto-named
# snapshots trigger a daemon bug where the ZFS snapshot + DB entry are
# created but the client never gets a response). Run async and poll.
test_snapshotme() {
  ssh_host "$TOOL delete -f my-snap1" 2>/dev/null || true
  ssh_lxd "user@my-snap1${VM_SUFFIX}.${DOMAIN}" true
  sleep 2
  ssh_host "$TOOL exec my-snap1 -- sudo touch /snapshotme"
  sleep 1
  ssh_host "cd /vmtree && { bash cron-snapshotme.sh &>/dev/null & }"
  # Poll for snapshot to appear (max 120s)
  for _ in $(seq 1 24); do
    if ssh_host "$TOOL info my-snap1 | awk '/^Snapshots:/{getline; print; exit}' | grep -q ." 2>/dev/null; then
      break
    fi
    sleep 5
  done
  # marker file consumed by cron
  ssh_host "! $TOOL file pull my-snap1/snapshotme - 2>/dev/null"
  # snapshot exists
  ssh_host "$TOOL info my-snap1 | awk '/^Snapshots:/{getline; print; exit}' | grep -q ."
  ssh_host "$TOOL delete -f my-snap1" 2>/dev/null || true
}

# Launch a VM (not container) via the -vm suffix, verify it boots.
# XXX: Works but eats ~1GB RAM; only runs when VM= (container mode).
test_vm_machine() {
  local vm_suf="-ubuntu${OS}04-vm1"
  ssh_host "$TOOL delete -f my-vm1" 2>/dev/null || true
  out=$(ssh_lxd "user@my-vm1${vm_suf}.${DOMAIN}" 'echo VM-OK')
  [[ "$out" == *"VM-OK"* ]]
  ssh_host "$TOOL list --format csv -c nt | grep -q 'my-vm1.*VIRTUAL-MACHINE'"
  ssh_host "$TOOL delete -f my-vm1"
}

# /nokill prevents deletion by nightly cron-stop.sh (but VM is still stopped).
# Runs LAST: cron-stop.sh processes ALL my-* VMs.
test_nokill() {
  ssh_host "$TOOL delete -f my-safe1" 2>/dev/null || true
  ssh_host "$TOOL delete -f my-gone1" 2>/dev/null || true
  ssh_lxd "user@my-safe1${VM_SUFFIX}.${DOMAIN}" true
  ssh_lxd "user@my-gone1${VM_SUFFIX}.${DOMAIN}" true
  sleep 2
  ssh_host "$TOOL exec my-safe1 -- sudo touch /nokill"
  ssh_host 'cd /vmtree && bash cron-stop.sh'
  # safe1 stopped but exists
  ssh_host "$TOOL info my-safe1 >/dev/null"
  # gone1 deleted
  ! ssh_host "$TOOL info my-gone1 >/dev/null 2>&1"
  ssh_host "$TOOL delete -f my-safe1" 2>/dev/null || true
}
test_cron()           { ssh_host "crontab -l 2>/dev/null | grep -q cron-killme"; } # Not necessary.

# -- run --
if [[ $# -gt 0 ]]; then
  ip=$(get_ip || true)
  [[ -n "$ip" ]] && DOMAIN="${ip}.nip.io"
  for f; do "$f"; done
else
  setup
  test_caddy_active
  test_vmtree_user
  test_storage_pool
  test_force_command
  test_create_vm
  test_vm_running
  test_vm_ping
  test_caddy_proxy
  test_caddy_auth_required
  test_caddy_nopassword
  test_persist_survives
  test_killme
  test_snapshotme
  test_idempotent
  test_cron
  test_nokill
  [[ -z "$VM" ]] && test_vm_machine  # redundant when VM=1, all tests already exercise VMs
  echo "✅ all passed"
fi

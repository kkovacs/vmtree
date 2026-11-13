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
  # NORETRY=1: single attempt (the probe+real double-run breaks "ssh -f" tunnels)
  [[ -n "${NORETRY:-}" ]] && { timeout 120 "${sc[@]}" "$@"; return $?; }
  local a=0 rc
  while (( a < 4 )); do
    # Quiet probe; retry only on ssh errors (255) and timeouts (124).
    # (rc must be captured via "||": $? after a failed "if" without else is 0.)
    rc=0
    timeout 120 "${sc[@]}" "$@" >/dev/null 2>&1 || rc=$?
    (( rc == 0 )) && { timeout 180 "${sc[@]}" "$@"; return $?; }
    [[ $rc -ne 255 && $rc -ne 124 ]] && return $rc
    ((++a))  # not a++: that evaluates to 0 on the first pass and trips set -e
    sleep $((2 ** a))
  done
  timeout 180 "${sc[@]}" "$@"
}

# Poll until "$@" succeeds, failing after $1 seconds. Used for the every-minute
# cron jobs: running them by hand races with the real cron.
wait_for() {
  local t=$1 i; shift
  for ((i = 0; i < t; i += 5)); do
    "$@" && return 0
    sleep 5
  done
  return 1
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

# The requested VM name is client input: anything but "word(-word)*" must be rejected.
# (No '-x' case: ssh would parse it as its own option.)
test_invalid_vm_names() {
  local ip name out rc
  ip=$(get_ip)
  for name in 'a b' '*' 'a;b' '$(id)' 'a--b'; do
    rc=0
    out=$(timeout 30 ssh "${SSH_OPTS[@]}" "vmtree@$ip" "$name" 2>&1 </dev/null) || rc=$?
    [[ $rc -ne 0 && "$out" == *"invalid VM name"* ]] || { echo "NOT REJECTED: '$name' rc=$rc out=$out"; return 1; }
  done
}

# The forced command must win over: a real command that is also a valid VM name,
# an interactive login, and the sftp subsystem (modern scp uses sftp too).
test_force_command() {
  local ip out rc
  ip=$(get_ip)
  rc=0; out=$(timeout 30 ssh "${SSH_OPTS[@]}" "vmtree@$ip" id 2>&1 </dev/null) || rc=$?
  [[ $rc -ne 0 && "$out" != *"uid="* ]] || { echo "'id' RAN: rc=$rc out=$out"; return 1; }
  # -T, not -tt: with -tt the CLIENT aborts on restrict's PTY refusal, never reaching the server side
  rc=0; out=$(timeout 30 ssh -T "${SSH_OPTS[@]}" "vmtree@$ip" 2>&1 </dev/null) || rc=$?
  [[ $rc -ne 0 && "$out" == *"invalid VM name"* ]] || { echo "LOGIN NOT BLOCKED: rc=$rc out=$out"; return 1; }
  rc=0; out=$(echo ls | timeout 30 sftp -b - "${SSH_OPTS[@]}" "vmtree@$ip" 2>&1) || rc=$?
  [[ $rc -ne 0 ]] || { echo "SFTP WORKS: out=$out"; return 1; }
}

# The outer vmtree@host session must NOT allow port forwarding to the host
# (e.g. Caddy admin API on 127.0.0.1:2019).
test_no_host_forwarding() {
  local ip sock crc=0 rc=0
  ip=$(get_ip)
  sock=$(mktemp -u /tmp/vmtree-nofwd.XXXXXX)
  # Positive control: the target must be reachable from the host itself
  ssh_host "curl -sf -m 5 http://127.0.0.1:2019/config/ >/dev/null"
  # -N: no command, so the forced command never runs and the tunnel stays up
  ssh -f -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -o ControlMaster=yes -o ControlPath="$sock" \
    -L 127.0.0.1:12019:127.0.0.1:2019 "vmtree@$ip"
  curl -s -m 5 http://127.0.0.1:12019/config/ >/dev/null 2>&1 || crc=$?
  ssh -o ControlPath="$sock" -O exit "vmtree@$ip" 2>/dev/null || true
  # curl 7 = nothing listening locally, i.e. the tunnel never existed: test proves nothing
  [[ $crc -ne 0 && $crc -ne 7 ]] || { echo "host forwarding NOT blocked (or no tunnel), curl rc=$crc"; rc=1; }
  return $rc
}

# Port forwarding INSIDE the VM (through the ProxyCommand) must keep working.
test_vm_forwarding() {
  local sock target rc=1 i
  sock=$(mktemp -u /tmp/vmtree-fwd.XXXXXX)
  target="user@my-test1${VM_SUFFIX}.${DOMAIN}"
  ssh_host "$TOOL exec my-test1 -- bash -c 'echo fwd-ok >/tmp/fwd.txt; cd /tmp; setsid nohup python3 -m http.server 8080 >/dev/null 2>&1 </dev/null &'"
  NORETRY=1 ssh_lxd -f -N -o ExitOnForwardFailure=yes -o ControlMaster=yes -o ControlPath="$sock" \
    -L 127.0.0.1:18080:127.0.0.1:8080 "$target"
  for i in {1..15}; do
    curl -sf -m 2 http://127.0.0.1:18080/fwd.txt | grep -q fwd-ok && { rc=0; break; }
    sleep 1
  done
  ssh -o ControlPath="$sock" -O exit "$target" 2>/dev/null || true
  ssh_host "$TOOL exec my-test1 -- pkill -f 'http.server 8080'" || true
  return $rc
}

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
  # http.server is left running on purpose: the next two caddy tests use it
  ssh_host "$TOOL exec my-web1 -- bash -c \"echo hello-vmtree > /tmp/test.txt && cd /tmp && setsid nohup python3 -m http.server 80 >/dev/null 2>&1 </dev/null &\""
  local i
  for i in {1..30}; do
    curl -sk -u "testuser:testpass" "https://my-web1.${DOMAIN}/test.txt" | grep -q hello-vmtree && return 0
    sleep 1
  done
  return 1
}

test_caddy_auth_required() {
  curl -sk -o /dev/null -w '%{http_code}' "https://my-web1.${DOMAIN}/test.txt" | grep -q 401
}

test_caddy_nopassword() {
  ssh_host "$TOOL exec my-web1 -- sudo touch /nopassword"
  wait_for 90 bash -c "curl -sk -o /dev/null -w '%{http_code}' 'https://my-web1.${DOMAIN}/test.txt' | grep -q 200"
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
  # Negate REMOTELY: a local "!" would turn an ssh failure (255) into a pass
  wait_for 90 ssh_host "! $TOOL info my-kill1 >/dev/null 2>&1"
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
# created but the client never gets a response). The crontab's "timeout 600"
# frees the lock; the marker then stays, so the next run snapshots again.
test_snapshotme() {
  ssh_host "$TOOL delete -f my-snap1" 2>/dev/null || true
  ssh_lxd "user@my-snap1${VM_SUFFIX}.${DOMAIN}" true
  sleep 2
  ssh_host "$TOOL exec my-snap1 -- sudo touch /snapshotme"
  # Snapshot exists AND marker consumed (the script deletes it after snapshotting)
  wait_for 150 ssh_host "$TOOL info my-snap1 | awk '/^Snapshots:/{getline; print; exit}' | grep -q . && ! $TOOL file pull my-snap1/snapshotme - >/dev/null 2>&1"
  ssh_host "$TOOL delete -f my-snap1" 2>/dev/null || true
}

# Launch a VM (not container) via the -vm suffix, verify it boots.
# XXX: Works but eats ~1GB RAM; only runs when VM= (container mode).
test_vm_machine() {
  local vm_suf="-ubuntu${OS}04-vm1" out
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
  ssh_host "$TOOL list --format csv -c ns | grep -q '^my-safe1,STOPPED$'"
  # gone1 deleted (negated remotely: a local "!" is ignored by set -e when not last)
  ssh_host "! $TOOL info my-gone1 >/dev/null 2>&1"
  ssh_host "$TOOL delete -f my-safe1" 2>/dev/null || true
}

# All active cron jobs from install.sh (cron-renew is commented out for selfsigned)
test_cron() {
  local c
  for c in stop killme snapshotme nopassword; do
    ssh_host "crontab -l | grep -q '^[^#].*/vmtree/cron-$c\.sh'"
  done
}

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
  test_invalid_vm_names
  test_force_command
  test_create_vm
  test_vm_running
  test_no_host_forwarding
  test_vm_forwarding
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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.state"
SSH_KEY="${STATE_DIR}/id_ed25519"

VM_NAME="${NEWMINHH_VM_NAME:-newminhh-x32}"
LIBVIRT_URI="${NEWMINHH_LIBVIRT_URI:-qemu:///system}"
LIBVIRT_NET="${NEWMINHH_LIBVIRT_NET:-default}"
WAIT_SECS="${NEWMINHH_VM_WAIT_SECS:-120}"

if ! virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "ERROR: domain '${VM_NAME}' is not defined. Run ${SCRIPT_DIR}/vm-provision.sh first." >&2
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH private key not found at ${SSH_KEY}" >&2
  exit 1
fi

net_active="$(virsh -c "$LIBVIRT_URI" net-info "$LIBVIRT_NET" | awk -F': *' '/^Active:/{print $2}')"
if [[ "$net_active" != "yes" ]]; then
  echo "[vm-up] Starting libvirt network '${LIBVIRT_NET}'..."
  virsh -c "$LIBVIRT_URI" net-start "$LIBVIRT_NET" >/dev/null
fi

state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" | tr -d '\r')"
case "$state" in
  "shut off")
    echo "[vm-up] Starting domain '${VM_NAME}'..."
    virsh -c "$LIBVIRT_URI" start "$VM_NAME" >/dev/null
    ;;
  "paused")
    echo "[vm-up] Resuming paused domain '${VM_NAME}'..."
    virsh -c "$LIBVIRT_URI" resume "$VM_NAME" >/dev/null
    ;;
  "running")
    echo "[vm-up] Domain '${VM_NAME}' is already running."
    ;;
  *)
    echo "ERROR: unexpected domain state: '${state}'" >&2
    exit 1
    ;;
esac

resolve_ip() {
  local ip=""
  ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}')"
  if [[ -z "$ip" ]]; then
    ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$VM_NAME" --source arp 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}')"
  fi
  printf '%s' "$ip"
}

echo "[vm-up] Waiting for DHCP lease / IP address..."
GUEST_IP=""
deadline=$(( $(date +%s) + WAIT_SECS ))
while [[ $(date +%s) -lt $deadline ]]; do
  GUEST_IP="$(resolve_ip || true)"
  if [[ -n "$GUEST_IP" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$GUEST_IP" ]]; then
  echo "ERROR: timed out waiting for guest IP from domifaddr (--source lease / --source arp)" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
printf '%s\n' "$GUEST_IP" > "${STATE_DIR}/guest_ip"
echo "[vm-up] Guest IP: ${GUEST_IP}"

echo "[vm-up] Waiting for SSH readiness on ${GUEST_IP}..."
deadline=$(( $(date +%s) + WAIT_SECS ))
while [[ $(date +%s) -lt $deadline ]]; do
  cur_ip="$(resolve_ip || true)"
  if [[ -n "$cur_ip" && "$cur_ip" != "$GUEST_IP" ]]; then
    GUEST_IP="$cur_ip"
    printf '%s\n' "$GUEST_IP" > "${STATE_DIR}/guest_ip"
    echo "[vm-up] Updated Guest IP: ${GUEST_IP}"
  fi
  if ssh -F /dev/null \
      -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=3 \
      "root@${GUEST_IP}" "true" 2>/dev/null; then
    printf '%s\n' "$GUEST_IP" > "${STATE_DIR}/guest_ip"
    console_ep="$(virsh -c "$LIBVIRT_URI" dumpxml "$VM_NAME" 2>/dev/null | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
s = root.find(\"./devices/serial[@type='tcp']/source\")
if s is not None:
    print(f\"{s.get('host', '127.0.0.1')}:{s.get('service', '')}\")
" || true)"
    echo "[vm-up] VM '${VM_NAME}' is UP and SSH-ready at ${GUEST_IP}."
    if [[ -n "$console_ep" ]]; then
      echo "[vm-up] Serial console exposed at tcp://${console_ep} (use ${SCRIPT_DIR}/vm-console.sh or socat PTY -> tio/screen)."
    fi
    exit 0
  fi
  sleep 2
done

echo "ERROR: timed out waiting for SSH on root@${GUEST_IP}" >&2
exit 1

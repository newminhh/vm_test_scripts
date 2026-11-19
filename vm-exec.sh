#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.state"
SSH_KEY="${STATE_DIR}/id_ed25519"

VM_NAME="${NEWMINHH_VM_NAME:-newminhh-x32}"
LIBVIRT_URI="${NEWMINHH_LIBVIRT_URI:-qemu:///system}"

usage() {
  cat <<EOF
Usage:
  $0 -- <command...>
  $0 --sync <local_dir> <remote_dir>
  $0 --ip
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key not found at ${SSH_KEY}. Run ${SCRIPT_DIR}/vm-provision.sh first." >&2
  exit 1
fi

get_guest_ip() {
  local ip=""
  ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}')"
  if [[ -z "$ip" ]]; then
    ip="$(virsh -c "$LIBVIRT_URI" domifaddr "$VM_NAME" --source arp 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}')"
  fi
  if [[ -z "$ip" && -f "${STATE_DIR}/guest_ip" ]]; then
    ip="$(cat "${STATE_DIR}/guest_ip")"
  fi
  printf '%s' "$ip"
}

SSH_OPTS=(
  -F /dev/null
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)

GUEST_IP="$(get_guest_ip)"
if [[ -z "$GUEST_IP" ]]; then
  echo "ERROR: could not determine guest IP for '${VM_NAME}'. Is it running (${SCRIPT_DIR}/vm-up.sh)?" >&2
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  --ip)
    printf '%s\n' "$GUEST_IP"
    exit 0
    ;;
  --sync)
    if [[ $# -ne 3 ]]; then
      echo "ERROR: --sync requires <local_dir> <remote_dir>" >&2
      exit 2
    fi
    LOCAL_DIR="$2"
    REMOTE_DIR="$3"
    if [[ ! -d "$LOCAL_DIR" ]]; then
      echo "ERROR: local directory does not exist: ${LOCAL_DIR}" >&2
      exit 1
    fi
    ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" "mkdir -p $(printf '%q' "$REMOTE_DIR")"
    rsync -az -e "ssh ${SSH_OPTS[*]}" "${LOCAL_DIR%/}/" "root@${GUEST_IP}:${REMOTE_DIR%/}/"
    exit $?
    ;;
  --)
    shift
    if [[ $# -eq 0 ]]; then
      echo "ERROR: missing command after --" >&2
      exit 2
    fi
    ;;
esac

if [[ $# -eq 1 ]]; then
  exec ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" "$1"
else
  printf -v REMOTE_CMD '%q ' "$@"
  exec ssh "${SSH_OPTS[@]}" "root@${GUEST_IP}" "$REMOTE_CMD"
fi

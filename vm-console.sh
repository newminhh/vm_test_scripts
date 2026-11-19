#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${NEWMINHH_VM_NAME:-newminhh-x32}"
LIBVIRT_URI="${NEWMINHH_LIBVIRT_URI:-qemu:///system}"
PTY_LINK="${NEWMINHH_VM_CONSOLE_PTY:-/tmp/${VM_NAME}-console.pty}"

usage() {
  cat <<EOF
Usage: $0 [--tio | --screen | --pty | --endpoint]
Attaches to or exposes a PTY bridge for ${VM_NAME}'s TCP serial console.
  --endpoint   Print host:port of the VM's TCP serial console and exit.
  --pty        Create a persistent foreground socat PTY bridge at ${PTY_LINK}
               so you can attach in another terminal with:
                 tio ${PTY_LINK}
                 screen ${PTY_LINK} 115200
  --tio        Start a background socat PTY bridge and attach with 'tio' (default if tio installed).
  --screen     Start a background socat PTY bridge and attach with 'screen'.
EOF
}

get_endpoint() {
  virsh -c "$LIBVIRT_URI" dumpxml "$VM_NAME" 2>/dev/null | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
s = root.find(\"./devices/serial[@type='tcp']/source\")
if s is None:
    sys.exit(1)
print(f\"{s.get('host', '127.0.0.1')}:{s.get('service', '')}\")
"
}

MODE=""
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
elif [[ $# -eq 1 ]]; then
  case "$1" in
    --endpoint) MODE="endpoint" ;;
    --pty) MODE="pty" ;;
    --tio) MODE="tio" ;;
    --screen) MODE="screen" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
else
  if command -v tio >/dev/null 2>&1; then
    MODE="tio"
  elif command -v screen >/dev/null 2>&1; then
    MODE="screen"
  else
    MODE="pty"
  fi
fi

ENDPOINT="$(get_endpoint)" || {
  echo "ERROR: TCP serial console not configured on '${VM_NAME}'. Run ${SCRIPT_DIR}/vm-provision.sh --update-xml" >&2
  exit 1
}

if [[ "$MODE" == "endpoint" ]]; then
  printf '%s\n' "$ENDPOINT"
  exit 0
fi

for cmd in socat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required tool missing: $cmd" >&2
    exit 1
  fi
done

if [[ "$MODE" == "pty" ]]; then
  trap 'rm -f "$PTY_LINK"' EXIT INT TERM
  echo "[vm-console] Bridging tcp://${ENDPOINT} <-> ${PTY_LINK} (Ctrl-C to stop)"
  echo "[vm-console] Attach with: tio ${PTY_LINK}  OR  screen ${PTY_LINK} 115200"
  while true; do
    rm -f "$PTY_LINK"
    socat "PTY,link=${PTY_LINK},raw,echo=0,waitslave" "TCP:${ENDPOINT}" || break
  done
  exit 0
fi

rm -f "$PTY_LINK"
socat "PTY,link=${PTY_LINK},raw,echo=0,waitslave" "TCP:${ENDPOINT}" &
SOCAT_PID=$!
trap 'kill "$SOCAT_PID" 2>/dev/null || true; rm -f "$PTY_LINK"' EXIT INT TERM

for _ in $(seq 1 50); do
  if [[ -e "$PTY_LINK" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -e "$PTY_LINK" ]]; then
  echo "ERROR: timed out waiting for PTY ${PTY_LINK}" >&2
  exit 1
fi

if [[ "$MODE" == "tio" ]]; then
  tio "$PTY_LINK"
elif [[ "$MODE" == "screen" ]]; then
  screen "$PTY_LINK" 115200
fi

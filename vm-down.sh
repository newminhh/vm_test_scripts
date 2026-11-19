#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.state"

VM_NAME="${NEWMINHH_VM_NAME:-newminhh-x32}"
LIBVIRT_URI="${NEWMINHH_LIBVIRT_URI:-qemu:///system}"
LIBVIRT_POOL="${NEWMINHH_LIBVIRT_POOL:-default}"
WAIT_SECS="${NEWMINHH_VM_SHUTDOWN_WAIT:-30}"

UNDEFINE=0
PURGE=0

usage() {
  cat <<EOF
Usage: $0 [--undefine] [--purge]
Gracefully shuts down '${VM_NAME}' (falling back to destroy after ${WAIT_SECS}s).
  --undefine   Undefine the libvirt domain after stopping.
  --purge      Undefine the domain, delete libvirt pool volumes, and remove vm/.state/.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --undefine) UNDEFINE=1; shift ;;
    --purge) UNDEFINE=1; PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
  state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" | tr -d '\r')"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    if [[ "$state" == "paused" ]]; then
      virsh -c "$LIBVIRT_URI" resume "$VM_NAME" >/dev/null || true
    fi
    if [[ -f "${STATE_DIR}/id_ed25519" ]]; then
      echo "[vm-down] Requesting clean guest poweroff via SSH..."
      "${SCRIPT_DIR}/vm-exec.sh" -- "sync && systemctl poweroff" >/dev/null 2>&1 || true
    fi
    echo "[vm-down] Sending ACPI shutdown to '${VM_NAME}'..."
    virsh -c "$LIBVIRT_URI" shutdown "$VM_NAME" >/dev/null || true
    deadline=$(( $(date +%s) + WAIT_SECS ))
    while [[ $(date +%s) -lt $deadline ]]; do
      state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null | tr -d '\r' || true)"
      if [[ "$state" == "shut off" || -z "$state" ]]; then
        break
      fi
      sleep 1
    done
    state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null | tr -d '\r' || true)"
    if [[ "$state" != "shut off" && -n "$state" ]]; then
      echo "[vm-down] Domain did not stop within ${WAIT_SECS}s; forcing destroy..."
      virsh -c "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null
    fi
  else
    echo "[vm-down] Domain '${VM_NAME}' is already ${state}."
  fi

  if [[ "$UNDEFINE" -eq 1 ]]; then
    echo "[vm-down] Undefining domain '${VM_NAME}'..."
    virsh -c "$LIBVIRT_URI" undefine "$VM_NAME" >/dev/null
  fi
else
  echo "[vm-down] Domain '${VM_NAME}' is not defined."
fi

if [[ "$PURGE" -eq 1 ]]; then
  for vol in "${VM_NAME}.qcow2" "${VM_NAME}-vmlinuz" "${VM_NAME}-initrd.img"; do
    if virsh -c "$LIBVIRT_URI" vol-info --pool "$LIBVIRT_POOL" "$vol" >/dev/null 2>&1; then
      echo "[vm-down] Deleting volume '${vol}' from pool '${LIBVIRT_POOL}'..."
      virsh -c "$LIBVIRT_URI" vol-delete --pool "$LIBVIRT_POOL" "$vol" >/dev/null
    fi
  done
  rm -rf "$STATE_DIR"
  echo "[vm-down] Purged libvirt volumes and ${STATE_DIR}."
fi

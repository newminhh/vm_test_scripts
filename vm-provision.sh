#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.state"

VM_NAME="${NEWMINHH_VM_NAME:-newminhh-x32}"
VM_VCPUS="${NEWMINHH_VM_VCPUS:-4}"
VM_MEMORY_MIB="${NEWMINHH_VM_MEMORY_MIB:-2048}"
VM_DISK_SIZE="${NEWMINHH_VM_DISK_SIZE:-6G}"
LIBVIRT_URI="${NEWMINHH_LIBVIRT_URI:-qemu:///system}"
LIBVIRT_POOL="${NEWMINHH_LIBVIRT_POOL:-default}"
LIBVIRT_NET="${NEWMINHH_LIBVIRT_NET:-default}"
VM_CONSOLE_HOST="${NEWMINHH_VM_CONSOLE_HOST:-127.0.0.1}"
VM_CONSOLE_PORT="${NEWMINHH_VM_CONSOLE_PORT:-4555}"

DISK_VOL="${VM_NAME}.qcow2"
KERNEL_VOL="${VM_NAME}-vmlinuz"
INITRD_VOL="${VM_NAME}-initrd.img"

CACHE_DIR="/tmp/newminhh-vm-cache"
FORCE=0
UPDATE_XML=0

usage() {
  cat <<EOF
Usage: $0 [--force] [--update-xml]
Provisions the Debian x32 libvirt-qemu VM (${VM_NAME}) without sudo.
  --force       Destroy/undefine existing VM & volumes and re-provision from scratch.
  --update-xml  Re-render domain.xml from domain.xml.in and redefine the domain without rebuilding disk.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --update-xml) UPDATE_XML=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for cmd in docker virsh qemu-img ssh-keygen python3 curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required host tool missing: $cmd" >&2
    exit 1
  fi
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

SSH_KEY="${STATE_DIR}/id_ed25519"
if [[ ! -f "$SSH_KEY" || ! -f "${SSH_KEY}.pub" ]]; then
  echo "[provision] Generating SSH ed25519 keypair in ${SSH_KEY}"
  rm -f "$SSH_KEY" "${SSH_KEY}.pub"
  ssh-keygen -t ed25519 -N "" -C "${VM_NAME}" -f "$SSH_KEY" >/dev/null
fi
chmod 600 "$SSH_KEY"
chmod 644 "${SSH_KEY}.pub"

vol_exists() {
  virsh -c "$LIBVIRT_URI" vol-info --pool "$LIBVIRT_POOL" "$1" >/dev/null 2>&1
}

dom_exists() {
  virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1
}

render_and_define_domain() {
  local disk_path kernel_path initrd_path domain_xml existing_uuid="" existing_mac=""
  disk_path="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$LIBVIRT_POOL" "$DISK_VOL")"
  kernel_path="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$LIBVIRT_POOL" "$KERNEL_VOL")"
  initrd_path="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$LIBVIRT_POOL" "$INITRD_VOL")"
  if dom_exists; then
    existing_uuid="$(virsh -c "$LIBVIRT_URI" domuuid "$VM_NAME" 2>/dev/null | tr -d '[:space:]' || true)"
    existing_mac="$(virsh -c "$LIBVIRT_URI" domiflist "$VM_NAME" 2>/dev/null | awk '/network/{print $5; exit}' || true)"
  fi

  domain_xml="${STATE_DIR}/domain.xml"
  python3 - "${SCRIPT_DIR}/domain.xml.in" "$domain_xml" \
    "$VM_NAME" "$VM_VCPUS" "$VM_MEMORY_MIB" "$disk_path" "$kernel_path" "$initrd_path" "$LIBVIRT_NET" "$VM_CONSOLE_HOST" "$VM_CONSOLE_PORT" "$existing_uuid" "$existing_mac" <<'PY'
import sys
tmpl_path, out_path, vm_name, vcpus, mem, disk, kernel, initrd, net, chost, cport, uuid, mac = sys.argv[1:]
with open(tmpl_path, "r", encoding="utf-8") as f:
    text = f.read()
for k, v in {
    "@VM_NAME@": vm_name,
    "@VM_VCPUS@": vcpus,
    "@VM_MEMORY_MIB@": mem,
    "@DISK_PATH@": disk,
    "@KERNEL_PATH@": kernel,
    "@INITRD_PATH@": initrd,
    "@NET_NAME@": net,
    "@CONSOLE_HOST@": chost,
    "@CONSOLE_PORT@": cport,
}.items():
    text = text.replace(k, v)
if uuid:
    text = text.replace(f"<name>{vm_name}</name>", f"<name>{vm_name}</name>\n  <uuid>{uuid}</uuid>", 1)
if mac:
    text = text.replace(f"<source network='{net}'/>", f"<mac address='{mac}'/>\n      <source network='{net}'/>", 1)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
PY

  echo "[provision] Defining libvirt domain '${VM_NAME}' (console tcp://${VM_CONSOLE_HOST}:${VM_CONSOLE_PORT})..."
  virsh -c "$LIBVIRT_URI" define "$domain_xml" >/dev/null
}

if [[ "$UPDATE_XML" -eq 1 ]] && vol_exists "$DISK_VOL" && vol_exists "$KERNEL_VOL" && vol_exists "$INITRD_VOL"; then
  render_and_define_domain
  echo "[provision] Domain XML updated. Restart VM if currently running for changes to take effect."
  exit 0
fi

if [[ "$FORCE" -eq 0 ]] && dom_exists && vol_exists "$DISK_VOL" && vol_exists "$KERNEL_VOL" && vol_exists "$INITRD_VOL"; then
  echo "[provision] VM '${VM_NAME}' and all libvirt volumes already exist (use --force to rebuild, or --update-xml to update domain XML)."
  exit 0
fi

if dom_exists; then
  echo "[provision] Removing existing domain '${VM_NAME}'..."
  state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "paused" ]]; then
    virsh -c "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null
  fi
  virsh -c "$LIBVIRT_URI" undefine "$VM_NAME" >/dev/null
fi

for vol in "$DISK_VOL" "$KERNEL_VOL" "$INITRD_VOL"; do
  if vol_exists "$vol"; then
    echo "[provision] Deleting existing volume '${vol}'..."
    virsh -c "$LIBVIRT_URI" vol-delete --pool "$LIBVIRT_POOL" "$vol" >/dev/null
  fi
done

cleanup() {
  rm -rf "$CACHE_DIR"
}
trap cleanup EXIT

rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

echo "[provision] Resolving latest Debian sid standard amd64 kernel and checking x32 package availability..."
read -r KVER KBIN_URL KMOD_URL CAPSTONE_AVAILABLE < <(python3 - <<'PY'
import lzma
import re
import sys
import urllib.request

DEBIAN_MIRROR = "http://deb.debian.org/debian"
PORTS_MIRROR = "http://deb.debian.org/debian-ports"

def fetch_packages(url):
    req = urllib.request.Request(url, headers={"User-Agent": "newminhh-vm-provision/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return lzma.decompress(resp.read()).decode("utf-8", "replace")

def parse_stanzas(text):
    pkgs = {}
    for block in text.strip().split("\n\n"):
        if not block.strip():
            continue
        fields = {}
        last_key = None
        for line in block.splitlines():
            if line.startswith((" ", "\t")) and last_key:
                fields[last_key] += " " + line.strip()
            elif ": " in line:
                k, v = line.split(": ", 1)
                fields[k] = v.strip()
                last_key = k
        name = fields.get("Package")
        if name:
            pkgs.setdefault(name, []).append(fields)
    return pkgs

amd64_pkgs = parse_stanzas(fetch_packages(f"{DEBIAN_MIRROR}/dists/sid/main/binary-amd64/Packages.xz"))
if "linux-image-amd64" not in amd64_pkgs:
    sys.exit("ERROR: linux-image-amd64 not found in Debian sid binary-amd64")

meta = amd64_pkgs["linux-image-amd64"][-1]
deps = meta.get("Depends", "")
kver = None
for m in re.finditer(r"linux-image-([0-9][^,\s)]+-amd64)", deps):
    cand = m.group(1)
    if "cloud" in cand or "rt-" in cand:
        continue
    kver = cand
    break

if not kver:
    sys.exit(f"ERROR: could not resolve standard amd64 kernel from linux-image-amd64 Depends: {deps}")

kbin_name = f"linux-binary-{kver}"
kmod_name = f"linux-modules-{kver}"
if kbin_name not in amd64_pkgs or kmod_name not in amd64_pkgs:
    sys.exit(f"ERROR: missing {kbin_name} or {kmod_name} in Debian sid binary-amd64")

kbin_url = f"{DEBIAN_MIRROR}/{amd64_pkgs[kbin_name][-1]['Filename']}"
kmod_url = f"{DEBIAN_MIRROR}/{amd64_pkgs[kmod_name][-1]['Filename']}"

x32_pkgs = parse_stanzas(fetch_packages(f"{PORTS_MIRROR}/dists/sid/main/binary-x32/Packages.xz"))
capstone_avail = "1" if "libcapstone-dev" in x32_pkgs else "0"

print(f"{kver} {kbin_url} {kmod_url} {capstone_avail}")
PY
)

echo "[provision] Resolved kernel: ${KVER}"
echo "[provision]   linux-binary: ${KBIN_URL}"
echo "[provision]   linux-modules: ${KMOD_URL}"
echo "[provision]   libcapstone-dev available in debian-ports/sid x32: ${CAPSTONE_AVAILABLE}"

KBIN_DEB="${CACHE_DIR}/$(basename "$KBIN_URL")"
KMOD_DEB="${CACHE_DIR}/$(basename "$KMOD_URL")"

echo "[provision] Downloading kernel .deb packages into ${CACHE_DIR}..."
curl -fsSL --retry 3 -o "$KBIN_DEB" "$KBIN_URL"
curl -fsSL --retry 3 -o "$KMOD_DEB" "$KMOD_URL"
cp "${SSH_KEY}.pub" "${CACHE_DIR}/id_ed25519.pub"

BASE_PACKAGES="systemd,systemd-sysv,udev,kmod,initramfs-tools,busybox,openssh-server,sudo,ca-certificates,debian-ports-archive-keyring,iproute2,clang,gcc,g++,make,binutils,libc6-dev,linux-libc-dev,python3,rsync,file,procps,util-linux,e2fsprogs,nasm"
if [[ "$CAPSTONE_AVAILABLE" == "1" ]]; then
  BASE_PACKAGES="${BASE_PACKAGES},libcapstone-dev"
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

echo "[provision] Bootstrapping Debian x32 rootfs via docker (debian:sid-slim + mmdebstrap)..."
docker run --rm --privileged \
  --tmpfs /build:rw,exec,dev,suid,size=3G \
  -v "${CACHE_DIR}:/work" \
  -e DEBIAN_FRONTEND=noninteractive \
  -e KVER="$KVER" \
  -e KBIN_DEB="/work/$(basename "$KBIN_DEB")" \
  -e KMOD_DEB="/work/$(basename "$KMOD_DEB")" \
  -e BASE_PACKAGES="$BASE_PACKAGES" \
  -e VM_NAME="$VM_NAME" \
  -e HOST_UID="$HOST_UID" \
  -e HOST_GID="$HOST_GID" \
  debian:sid-slim bash -euo pipefail -c '
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  mmdebstrap python3 arch-test debian-ports-archive-keyring ca-certificates e2fsprogs passwd >/dev/null

ROOTFS=/build/rootfs
mkdir -p "$ROOTFS"

mmdebstrap \
  --architectures=x32 \
  --variant=minbase \
  --keyring=/usr/share/keyrings/debian-ports-archive-keyring.gpg \
  --dpkgopt="path-exclude=/usr/share/doc/*" \
  --dpkgopt="path-exclude=/usr/share/man/*" \
  --dpkgopt="path-exclude=/usr/share/locale/*" \
  --include="$BASE_PACKAGES" \
  sid \
  "$ROOTFS" \
  "deb [signed-by=/usr/share/keyrings/debian-ports-archive-keyring.gpg] http://deb.debian.org/debian-ports sid main"

echo "[container] Injecting kernel & modules (${KVER})..."
dpkg-deb -x "$KBIN_DEB" "$ROOTFS"
dpkg-deb -x "$KMOD_DEB" "$ROOTFS"

if [[ ! -f "${ROOTFS}/usr/lib/modules/${KVER}/vmlinuz" ]]; then
  echo "ERROR: vmlinuz not found at ${ROOTFS}/usr/lib/modules/${KVER}/vmlinuz" >&2
  exit 1
fi
cp "${ROOTFS}/usr/lib/modules/${KVER}/vmlinuz" /work/vmlinuz

mkdir -p "${ROOTFS}/etc/initramfs-tools"
cat > "${ROOTFS}/etc/initramfs-tools/modules" <<EOF
virtio_blk
virtio_pci
virtio_net
ext4
EOF

mount -t proc proc "${ROOTFS}/proc"
chroot "$ROOTFS" depmod -a "$KVER"
chroot "$ROOTFS" mkinitramfs -o "/boot/initrd.img-${KVER}" "$KVER"
umount "${ROOTFS}/proc"
cp "${ROOTFS}/boot/initrd.img-${KVER}" /work/initrd.img
rm -f "${ROOTFS}/boot/initrd.img-${KVER}"

echo "[container] Configuring guest networking, autologin, sudo, insecure dev settings, SSH, and apt..."
echo "$VM_NAME" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1 localhost ${VM_NAME}
::1       localhost ip6-localhost ip6-loopback
EOF

cat > "${ROOTFS}/etc/fstab" <<EOF
/dev/vda / ext4 defaults,noatime 0 1
EOF

mkdir -p "${ROOTFS}/etc/systemd/network"
cat > "${ROOTFS}/etc/systemd/network/20-wired.network" <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=ipv4
EOF

rm -f "${ROOTFS}/etc/resolv.conf"
cat > "${ROOTFS}/etc/resolv.conf" <<EOF
nameserver 192.168.122.1
EOF

chroot "$ROOTFS" systemctl enable systemd-networkd.service >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable ssh.service >/dev/null 2>&1 || true

# Autologin as root on virtual TTYs and serial console (ttyS0)
mkdir -p "${ROOTFS}/etc/systemd/system/getty@.service.d"
cat > "${ROOTFS}/etc/systemd/system/getty@.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin root --noreset --noclear - \${TERM}
EOF

mkdir -p "${ROOTFS}/etc/systemd/system/serial-getty@.service.d"
cat > "${ROOTFS}/etc/systemd/system/serial-getty@.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin root --noreset --noclear --keep-baud 115200,57600,38400,9600 - \${TERM}
EOF

# Passwordless root and passwordless sudo for all users
chroot "$ROOTFS" passwd -d root >/dev/null
mkdir -p "${ROOTFS}/etc/sudoers.d"
cat > "${ROOTFS}/etc/sudoers.d/99-newminhh-nopasswd" <<EOF
ALL ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "${ROOTFS}/etc/sudoers.d/99-newminhh-nopasswd"

# Permissive sysctl & resource limits for isolated dev/test VM
mkdir -p "${ROOTFS}/etc/sysctl.d"
cat > "${ROOTFS}/etc/sysctl.d/99-newminhh-insecure.conf" <<EOF
kernel.dmesg_restrict = 0
kernel.kptr_restrict = 0
kernel.yama.ptrace_scope = 0
kernel.perf_event_paranoid = -1
kernel.unprivileged_bpf_disabled = 0
vm.mmap_min_addr = 0
fs.suid_dumpable = 1
EOF

mkdir -p "${ROOTFS}/etc/security/limits.d"
cat > "${ROOTFS}/etc/security/limits.d/99-newminhh.conf" <<EOF
* soft core unlimited
* hard core unlimited
* soft memlock unlimited
* hard memlock unlimited
EOF

mkdir -p "${ROOTFS}/etc/ssh/sshd_config.d"
cat > "${ROOTFS}/etc/ssh/sshd_config.d/99-newminhh.conf" <<EOF
PubkeyAuthentication yes
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
KbdInteractiveAuthentication yes
MaxAuthTries 100
PerSourcePenalties no
UseDNS no
EOF

mkdir -p "${ROOTFS}/root/.ssh"
cp /work/id_ed25519.pub "${ROOTFS}/root/.ssh/authorized_keys"
chmod 700 "${ROOTFS}/root/.ssh"
chmod 600 "${ROOTFS}/root/.ssh/authorized_keys"
chown -R 0:0 "${ROOTFS}/root/.ssh"

cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb [signed-by=/usr/share/keyrings/debian-ports-archive-keyring.gpg] http://deb.debian.org/debian-ports sid main
deb [signed-by=/usr/share/keyrings/debian-ports-archive-keyring.gpg] http://deb.debian.org/debian-ports unreleased main
EOF

# Strip transient caches to minimize disk image footprint
rm -rf "${ROOTFS}/var/cache/apt/archives/"*.deb \
       "${ROOTFS}/var/cache/apt/archives/partial/"* \
       "${ROOTFS}/var/cache/apt/"*.bin \
       "${ROOTFS}/var/lib/apt/lists/"* \
       "${ROOTFS}/tmp/"* \
       "${ROOTFS}/var/tmp/"*

echo "[container] Building ext4 rootfs image..."
truncate -s 6G /work/rootfs.raw
mke2fs -t ext4 -L "$VM_NAME" -d "$ROOTFS" -F /work/rootfs.raw >/dev/null
chown "${HOST_UID}:${HOST_GID}" /work/rootfs.raw /work/vmlinuz /work/initrd.img
'

echo "[provision] Converting raw image to qcow2..."
qemu-img convert -f raw -O qcow2 "${CACHE_DIR}/rootfs.raw" "${CACHE_DIR}/${DISK_VOL}"
rm -f "${CACHE_DIR}/rootfs.raw" "${CACHE_DIR}"/*.deb

upload_vol() {
  local vol_name="$1"
  local src_file="$2"
  local format="$3"
  local size_bytes
  size_bytes="$(stat -c%s "$src_file")"
  echo "[provision] Uploading ${vol_name} (${size_bytes} bytes, ${format}) to libvirt pool '${LIBVIRT_POOL}'..."
  virsh -c "$LIBVIRT_URI" vol-create-as "$LIBVIRT_POOL" "$vol_name" "$size_bytes" --format "$format" >/dev/null
  virsh -c "$LIBVIRT_URI" vol-upload --pool "$LIBVIRT_POOL" "$vol_name" "$src_file" >/dev/null
}

upload_vol "$DISK_VOL" "${CACHE_DIR}/${DISK_VOL}" "qcow2"
upload_vol "$KERNEL_VOL" "${CACHE_DIR}/vmlinuz" "raw"
upload_vol "$INITRD_VOL" "${CACHE_DIR}/initrd.img" "raw"

render_and_define_domain

echo "[provision] Provisioning complete."
virsh -c "$LIBVIRT_URI" vol-info --pool "$LIBVIRT_POOL" "$DISK_VOL"

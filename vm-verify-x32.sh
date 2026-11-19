#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXEC="${SCRIPT_DIR}/vm-exec.sh"

echo "=== Verifying Debian x32-only VM ==="

"$EXEC" -- bash -euo pipefail -c '
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

uname_m="$(uname -m)"
echo "uname -m: ${uname_m}"
[[ "$uname_m" == "x86_64" ]] || fail "expected uname -m == x86_64, got ${uname_m}"

cmdline="$(cat /proc/cmdline)"
echo "/proc/cmdline: ${cmdline}"
[[ "$cmdline" == *"syscall.x32=y"* ]] || fail "/proc/cmdline missing syscall.x32=y"
[[ "$cmdline" == *"ia32_emulation=0"* ]] || fail "/proc/cmdline missing ia32_emulation=0"

dpkg_arch="$(dpkg --print-architecture)"
echo "dpkg --print-architecture: ${dpkg_arch}"
[[ "$dpkg_arch" == "x32" ]] || fail "expected dpkg arch == x32, got ${dpkg_arch}"

foreign_arches="$(dpkg --print-foreign-architectures)"
echo "dpkg --print-foreign-architectures: \"${foreign_arches}\""
[[ -z "$foreign_arches" ]] || fail "expected empty foreign architectures, got: ${foreign_arches}"

all_pkgs="$(dpkg-query -W -f="\${Package}:\${Architecture}\n")"
total_pkgs="$(printf "%s\n" "$all_pkgs" | wc -l)"
[[ "$total_pkgs" -gt 0 ]] || fail "dpkg-query returned zero packages"
i386_pkgs="$(printf "%s\n" "$all_pkgs" | grep ":i386$" || true)"
echo "total packages: ${total_pkgs}, i386 packages count: $(printf "%s" "$i386_pkgs" | grep -c . || true)"
[[ -z "$i386_pkgs" ]] || fail "found unexpected :i386 packages: ${i386_pkgs}"

if dpkg-query -W libc6-i386 >/dev/null 2>&1; then
  fail "libc6-i386 package must not be installed"
fi

if [[ -e /lib/ld-linux.so.2 || -e /lib32/libc.so.6 ]]; then
  fail "unexpected i386 dynamic linker or libc32 found on guest"
fi
echo "/lib/ld-linux.so.2: absent (OK)"

if [[ -e /libx32/ld-linux-x32.so.2 ]]; then
  echo "/libx32/ld-linux-x32.so.2: present ($(readlink -f /libx32/ld-linux-x32.so.2))"
elif [[ -e /lib/x86_64-linux-gnux32/ld-linux-x32.so.2 ]]; then
  echo "/lib/x86_64-linux-gnux32/ld-linux-x32.so.2: present"
else
  fail "x32 dynamic linker ld-linux-x32.so.2 not found"
fi

ls_hdr="$(readelf -h /bin/ls)"
echo "/bin/ls ELF header:"
printf "%s\n" "$ls_hdr" | grep -E "Class:|Machine:"
printf "%s\n" "$ls_hdr" | grep -q "ELF32" || fail "/bin/ls is not ELF32"
printf "%s\n" "$ls_hdr" | grep -q "Advanced Micro Devices X86-64" || fail "/bin/ls is not X86-64"

glibc_ver="$(dpkg-query -W -f="\${Version}\n" libc6)"
echo "glibc (libc6:x32) version: ${glibc_ver}"

if dpkg-query -W libcapstone-dev >/dev/null 2>&1; then
  cap_ver="$(dpkg-query -W -f="\${Version}\n" libcapstone-dev)"
  echo "libcapstone-dev: installed (version ${cap_ver})"
else
  echo "libcapstone-dev: NOT installed; checking apt policy..."
  apt-cache policy libcapstone-dev || true
fi

tmpdir="$(mktemp -d)"
trap "rm -rf \"$tmpdir\"" EXIT
cat > "${tmpdir}/smoke.c" <<EOF
#include <stdio.h>
#include <stdint.h>
int main(void) {
#if !defined(__x86_64__) || !defined(__ILP32__)
#error "Expected x32 (__x86_64__ && __ILP32__)"
#endif
    if (sizeof(void *) != 4 || sizeof(long) != 4 || sizeof(long long) != 8) {
        fprintf(stderr, "Unexpected sizes\n");
        return 1;
    }
    printf("X32_GCC_SMOKE_OK ptr=%zu long=%zu llong=%zu\n",
           sizeof(void *), sizeof(long), sizeof(long long));
    return 0;
}
EOF
gcc -O2 -Wall -Wextra -Werror "${tmpdir}/smoke.c" -o "${tmpdir}/smoke"
smoke_out="$("${tmpdir}/smoke")"
echo "gcc smoke test: ${smoke_out}"
[[ "$smoke_out" == "X32_GCC_SMOKE_OK ptr=4 long=4 llong=8" ]] || fail "unexpected smoke output: ${smoke_out}"
readelf -h "${tmpdir}/smoke" | grep -E "Class:|Machine:"

echo "=== ALL X32 VM VERIFICATION CHECKS PASSED ==="
'

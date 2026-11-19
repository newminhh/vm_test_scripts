# `newminhh/vm_test_scripts` — Debian `x32` `libvirt-qemu` Provisioning & Execution Scripts

Reproducible `libvirt-qemu` (`qemu:///system`) automation scripts for provisioning and running the isolated `x32`-only Debian test platform (`newminhh-x32`, booted with `syscall.x32=y ia32_emulation=0` and zero `:i386` packages):

- **`domain.xml.in`** — Libvirt domain XML template for `newminhh-x32`.
- **`vm-provision.sh`** — Bootstraps and configures the Debian `x32` guest image and SSH key state (`vm/.state/`, git-ignored).
- **`vm-up.sh` / `vm-down.sh`** — Starts and cleanly shuts down the `newminhh-x32` domain.
- **`vm-exec.sh`** — Syncs host directories and executes commands over SSH inside `newminhh-x32`.
- **`vm-verify-x32.sh`** — Verifies `x32`-only isolation (`syscall.x32=y ia32_emulation=0`, `dpkg --print-architecture == x32`, zero foreign architectures, zero `:i386` packages, `/lib/ld-linux.so.2` absent).
- **`vm-console.sh`** — Attaches to the guest serial console.

See [`newminhh/docs`](https://github.com/newminhh/docs) (`TESTING_AND_VM.md`) for full documentation.

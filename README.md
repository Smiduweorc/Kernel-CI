# Kernel-CI

A template for out-of-tree Linux kernel modules. CI builds every module
against several pinned kernel.org kernels with gcc and with clang, boots each
kernel in QEMU, runs the modules' KUnit suites and shell tests inside it, and
fails on anything the kernel complains about.

## Requirements

Linux on x86_64, with what a kernel build needs, plus a VM to boot it in:

```sh
sudo apt-get install bc bison flex libelf-dev libssl-dev clang lld llvm \
  sparse busybox-static cpio kmod qemu-system-x86
```

[mise](https://mise.jdx.dev) installs the rest (lefthook, git-cliff,
shellcheck, shfmt). Kernel sources and builds live under `.kci/`.

## Using it

```sh
bunx degit Smiduweorc/Kernel-CI my-module
cd my-module && git init && make setup
make vm                                    # newest kernel in ci/kernels, gcc
make vm KERNEL=6.12.118 TOOLCHAIN=clang
```

A module is a directory under `modules/` with a `Kbuild`. In the VM every
`*_kunit.ko` it builds is loaded, then its `test.sh` runs under busybox.
`modules/hello` has all three. `ci/kernels` lists the kernels with their
tarball checksums, and `ci/kernel.config` the debug options every test
kernel gets (KASAN, UBSAN, lockdep). `make build` compiles against your
running kernel's headers without booting anything.

A run fails on:

- a compiler warning at `W=1`, a sparse warning, or a modpost warning
- anything `checkpatch.pl --strict` reports
- a KUnit case that is not ok, or a suite that never reported
- a `test.sh` that exits non-zero
- a kernel BUG, WARN, oops, sanitizer report, RCU stall or hung task, with
  `panic_on_warn` set so the first one stops the VM
- a taint bit other than O (out-of-tree module) and N (KUnit ran)

## What it does not do

- Architectures other than x86_64. [KernelCI](https://kernelci.org) tests
  the kernel itself across real hardware.
- Patches to the kernel tree. Those go through `tools/testing/kunit/kunit.py
  run` and `checkpatch.pl` on the patch.
- Booting distribution kernels. Only kernel.org kernels are booted. Building
  against Ubuntu's, Fedora's or Arch's headers is covered in the guide below.
- Packaging. DKMS or your distribution's build system ships the module.
- Leak detection. kmemleak is not enabled: it reports only after a scan
  that runs asynchronously, and nothing here waits for one yet.

## Known quirks

- The first CI run for each kernel and toolchain builds the kernel from
  cold. It is cached after that until `ci/kernel.config` or the runner
  image changes.
- Without a usable `/dev/kvm`, `make vm` falls back to TCG, which is far
  slower. One run gets `VM_TIMEOUT` seconds (`scripts/tasks.sh`).
- `make lint` skips checkpatch until `make vm` has fetched the newest
  kernel once. CI always runs it.
- checkpatch's `LINUX_VERSION_CODE` warning is off, because a module built
  against several kernels has to compare versions.
- A KUnit case that skips counts as a pass, as KUnit itself counts it.
- Dependabot does not know about `ci/kernels`. Bump it by hand, taking the
  checksum from `sha256sums.asc` on cdn.kernel.org.

## Guides

- [Building against distribution kernels](guides/distro-kernels.md)

Commits follow Conventional Commits and `make release V=v1.2.0` cuts a
release; [black-garden-ants](https://github.com/Smiduweorc/black-garden-ants)
explains both. Nothing is published anywhere.

## License

GPL-2.0, the kernel's own. KUnit and most of the module API are exported to
GPL modules only.

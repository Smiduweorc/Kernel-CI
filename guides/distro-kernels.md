# Distribution kernels

`ci/kernels` pins kernel.org releases because those are the kernels CI can
rebuild with KASAN, UBSAN and lockdep and then boot. Most people who load the
module will run something else: Ubuntu's, Fedora's or Arch's kernel, with the
distribution's patches and its own config. This guide covers building against
those kernels. Booting them is not supported, and the last section says why.

## What you get

`make build` (`scripts/tasks.sh build`) compiles every module under `modules/`
against the build tree in `KDIR`, with the same rules as the VM runs: W=1
warnings, sparse and modpost warnings are all errors. Nothing is booted, so
KUnit, `test.sh`, the sanitizers and the taint check do not run. What it
proves is that the module compiles and links against that distribution's
headers and symbol versions, which is where distribution patches usually
break out-of-tree code.

## Locally

Install your running kernel's build tree, then build:

| Distribution | Package | Build tree |
| --- | --- | --- |
| Debian, Ubuntu | `linux-headers-$(uname -r)` | `/lib/modules/$(uname -r)/build` |
| Fedora | `kernel-devel-$(uname -r)` | `/lib/modules/$(uname -r)/build` |
| Arch | `linux-headers` (or `linux-lts-headers`) | `/lib/modules/$(uname -r)/build` |

```sh
make build
```

With no `KDIR`, the build uses `/lib/modules/$(uname -r)/build`. To build
against a kernel you are not running, point `KDIR` at its tree, for example
`KDIR=/usr/src/linux-headers-6.8.0-88-generic make build`.

Build with the compiler the distribution built the kernel with. The headers
record it:

```sh
grep CONFIG_CC_VERSION_TEXT "$KDIR/.config"
```

If it says clang, add `TOOLCHAIN=clang`. A different compiler from the one
the kernel was built with can fail on flags the other one does not know.

## In CI

Add a job next to `vm` in `.github/workflows/ci.yml`. It installs the headers
in a container of the distribution and runs the same task. Fedora as the
example:

```yaml
  fedora:
    name: Build against Fedora's kernel
    needs: lint
    runs-on: ubuntu-24.04
    container: fedora:43
    timeout-minutes: 20

    steps:
      - name: Checkout code
        uses: actions/checkout@v7

      - name: Install the kernel headers
        run: dnf install -y make gcc elfutils-libelf-devel sparse kernel-devel

      # The container runs the host's kernel, so uname -r says nothing about
      # the headers; take the version from the package.
      - name: Build the modules
        run: |
          KDIR=/usr/src/kernels/$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-devel)
          export KDIR
          scripts/tasks.sh build
```

The same shape works for other distributions. Change the image, the package
install, and where the tree lands:

- Ubuntu (`ubuntu:24.04`): `apt-get install -y make gcc sparse
  linux-headers-generic`, then `KDIR` is the directory under `/usr/src`
  ending in `-generic`.
- Debian (`debian:13`): `apt-get install -y make gcc sparse
  linux-headers-amd64`, then `KDIR` is the directory under `/usr/src`
  ending in `-amd64`.
- Arch (`archlinux:latest`): `pacman -Syu --noconfirm make gcc sparse
  linux-headers`, then `KDIR` is `build` inside the only directory in
  `/usr/lib/modules`.

Name the image version (`fedora:43`, not `fedora:latest`) so a new
distribution release changes the job in a commit you can see, not between two
runs of the same commit. The headers inside that release still move with its
updates, so the job tests "the current kernel of Fedora 43", not one fixed
kernel. That is the point of it, and also why a failure here can appear
without any change on your side.

## Why distribution kernels are not booted

`scripts/tasks.sh vm` is built around a kernel it compiled itself, and a
distribution kernel breaks each of the things it depends on:

- **The debug options are missing.** No distribution ships KASAN or lockdep
  on. A boot that passes proves much less than the kernel.org runs.
- **The image is hard to get.** Ubuntu installs `/boot/vmlinuz-*` readable
  by root only, and each distribution names and packages it differently.
- **Dependencies are compressed.** With `CONFIG_KUNIT=m` the KUnit module
  needs `kunit.ko`, which distributions ship as `.ko.zst` or `.ko.xz`.
  busybox's modprobe cannot load those.
- **The taint check changes.** Many distribution kernels sign their modules,
  so loading this unsigned one also sets E (bit 13), and `TAINT_ALLOWED` would
  have to allow it.

Each of these could be solved. Together they would make a second VM path,
nearly as large as the first, that tests less. If you need a module proven on
a distribution kernel at run time, boot that distribution's own cloud image
in a VM and load the module there. That is a different tool from this
template.

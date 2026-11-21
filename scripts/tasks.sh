#!/usr/bin/env sh
#
# The single definition of what this project's tasks mean.
#
# make, the git hooks and CI all shell out to this file, so there is exactly
# one place where "lint" is defined and the three entry points cannot drift
# apart.
#
# Usage: scripts/tasks.sh <task> [args...]
#        scripts/tasks.sh help

set -eu

say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

cliff() {
	have git-cliff || die "git-cliff not found. Run: scripts/tasks.sh setup"
	git-cliff "$@"
}

run_lefthook() {
	have lefthook || die "lefthook not found. Run: scripts/tasks.sh setup"
	command lefthook "$@"
}

# Kernel trees, VM images and logs. Downloads and kernel builds are slow to
# remake, so "clean" leaves them alone.
WORK=.kci
JOBS=$(getconf _NPROCESSORS_ONLN)

# How long one VM run may take, in seconds. It has to cover a KASAN kernel
# booting under TCG, the slow path without /dev/kvm, plus every module's
# tests.
VM_TIMEOUT=300

# Any taint bit outside these fails the run: O is set by loading an
# out-of-tree module and N by running KUnit tests, and both are expected here.
TAINT_ALLOWED=$((4096 | 262144))

kernel_versions() { awk '!/^#/ && NF { print $1 }' ci/kernels; }

latest_kernel() { kernel_versions | sort -V | tail -n 1; }

kernel_sha() {
	sha=$(awk -v v="$1" '!/^#/ && $1 == v { print $2 }' ci/kernels)
	[ -n "$sha" ] || die "kernel $1 is not listed in ci/kernels"
	printf '%s\n' "$sha"
}

# Every make against a kernel tree goes through here, so a kernel and the
# modules built against it cannot disagree about the compiler.
kmake() {
	toolchain=$1
	shift
	case "$toolchain" in
		gcc) make "$@" ;;
		clang) make LLVM=1 "$@" ;;
		*) die "unknown toolchain '$toolchain'; use gcc or clang" ;;
	esac
}

# Prints the source directory.
fetch_kernel() {
	version=$1
	sha=$(kernel_sha "$version")
	src=$WORK/src/linux-$version
	if [ -f "$src/Makefile" ]; then
		printf '%s\n' "$src"
		return 0
	fi

	tarball=$WORK/dl/linux-$version.tar.xz
	if [ ! -f "$tarball" ]; then
		say "Downloading linux-$version"
		mkdir -p "$WORK/dl"
		curl -fsSL --retry 3 --connect-timeout 30 --max-time 900 \
			-o "$tarball.part" \
			"https://cdn.kernel.org/pub/linux/kernel/v${version%%.*}.x/linux-$version.tar.xz"
		mv "$tarball.part" "$tarball"
	fi
	if ! printf '%s  %s\n' "$sha" "$tarball" | sha256sum -c --quiet - >&2; then
		rm -f "$tarball"
		die "linux-$version.tar.xz does not match its checksum in ci/kernels; deleted it"
	fi

	say "Unpacking linux-$version"
	part=$WORK/src/.linux-$version.part
	rm -rf "$part"
	mkdir -p "$part"
	tar -xJf "$tarball" -C "$part" --strip-components=1
	mv "$part" "$src"
	printf '%s\n' "$src"
}

# merge_config.sh only warns when Kconfig drops a requested option, and a
# kernel quietly built without KASAN still passes every test.
check_config() {
	missing=$(grep -v '^#' ci/kernel.config | grep . | while read -r line; do
		grep -qxF "$line" "$1" || printf '  %s\n' "$line"
	done)
	[ -z "$missing" ] || die "$(printf 'Kconfig dropped these ci/kernel.config lines:\n%s' "$missing")"
}

# Prints the build directory.
build_kernel() {
	version=$1
	toolchain=$2
	src=$(fetch_kernel "$version")
	build=$WORK/build/$version-$toolchain
	stamp=$(cat ci/kernel.config | sha256sum | cut -d' ' -f1)
	if [ -f "$build/.kci-stamp" ] && [ "$(cat "$build/.kci-stamp")" = "$stamp" ]; then
		printf '%s\n' "$build"
		return 0
	fi

	say "Building linux-$version with $toolchain"
	rm -rf "$build"
	mkdir -p "$build"
	out=$(cd "$build" && pwd)
	kmake "$toolchain" -C "$src" O="$out" -s defconfig >&2
	"$src/scripts/kconfig/merge_config.sh" -m -O "$out" "$out/.config" ci/kernel.config >&2
	kmake "$toolchain" -C "$src" O="$out" -s olddefconfig >&2
	check_config "$out/.config"
	kmake "$toolchain" -C "$src" O="$out" -s -j"$JOBS" >&2

	# Building modules against the tree needs its headers, generated files,
	# host tools, Module.symvers and System.map, and booting needs bzImage.
	# Objects and vmlinux are most of the size and none of that, so they
	# stay out of the CI cache.
	find "$out" \( -name '*.o' -o -name '*.a' -o -name '*.ko' \) -delete
	rm -f "$out/vmlinux"

	printf '%s\n' "$stamp" >"$build/.kci-stamp"
	printf '%s\n' "$build"
}

# Warnings are errors: compiler warnings at W=1, sparse, and modpost.
build_modules() {
	kdir=$1
	toolchain=$2
	sparse=""
	if have sparse; then
		sparse="C=1 CF=-Wsparse-error"
	elif [ -n "${CI:-}" ]; then
		die "sparse is not installed"
	else
		say "sparse not installed; building without it"
	fi

	log=$(mktemp)
	trap 'rm -f "$log"' EXIT
	for dir in modules/*/; do
		[ -f "$dir/Kbuild" ] || continue
		m=$PWD/${dir%/}
		say "Building $m against $kdir"
		kmake "$toolchain" -C "$kdir" M="$m" -s clean
		# shellcheck disable=SC2086 # $sparse is two make arguments or none
		if ! kmake "$toolchain" -C "$kdir" M="$m" W=1 KCFLAGS=-Werror $sparse modules >"$log" 2>&1; then
			cat "$log" >&2
			die "building $m failed"
		fi
		cat "$log" >&2
		if grep -q '^WARNING: modpost:' "$log"; then
			die "modpost warned about $m"
		fi
	done
}

# Prints the initramfs path. The guest gets a static busybox, ci/init, every
# module installed and indexed for modprobe, and every module's test.sh.
make_initramfs() {
	kdir=$1
	toolchain=$2
	out=$3
	busybox=$(command -v busybox) || die "busybox not found; install a static build (busybox-static on Debian and Ubuntu)"
	# The guest has no libc, so a dynamically linked busybox cannot start.
	if ldd "$busybox" >/dev/null 2>&1; then
		die "$busybox is dynamically linked; the VM needs a static busybox"
	fi

	root=$(pwd)/$out/root
	rm -rf "$root"
	mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys" "$root/kci/tests"
	cp "$busybox" "$root/bin/busybox"
	ln -s busybox "$root/bin/sh"
	cp ci/init "$root/init"
	chmod 755 "$root/init"

	for dir in modules/*/; do
		[ -f "$dir/Kbuild" ] || continue
		dir=${dir%/}
		# depmod runs once below, for every module together.
		kmake "$toolchain" -C "$kdir" M="$PWD/$dir" INSTALL_MOD_PATH="$root" \
			INSTALL_MOD_DIR=kci DEPMOD=true -s modules_install >&2
		if [ -f "$dir/test.sh" ]; then
			cp "$dir/test.sh" "$root/kci/tests/${dir##*/}.sh"
		fi
	done
	release=$(kmake "$toolchain" -C "$kdir" -s kernelrelease)
	depmod -b "$root" "$release"
	find "$root/lib/modules" -name '*_kunit.ko' | sed 's|.*/||; s|\.ko$||' | sort >"$root/kci/kunit"

	(cd "$root" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) | gzip -n >"$out/initramfs.cpio.gz"
	printf '%s\n' "$out/initramfs.cpio.gz"
}

run_vm() {
	image=$1
	initramfs=$2
	out=$3
	if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
		accel="-accel kvm -cpu host"
	elif [ -n "${CI:-}" ]; then
		die "/dev/kvm is not usable; the workflow enables it before this step"
	else
		say "/dev/kvm is not usable; falling back to TCG, which is far slower"
		accel="-accel tcg"
	fi

	rm -f "$out/console.log" "$out/results.log"
	status=0
	# shellcheck disable=SC2086 # $accel is several qemu arguments
	timeout -k 10 "$VM_TIMEOUT" qemu-system-x86_64 $accel -m 1G -smp 2 \
		-display none -monitor none -no-reboot \
		-kernel "$image" -initrd "$initramfs" \
		-append "console=ttyS0 rdinit=/init panic=-1 oops=panic panic_on_warn=1" \
		-chardev "stdio,id=console,logfile=$out/console.log" -serial chardev:console \
		-serial "file:$out/results.log" </dev/null || status=$?
	[ "$status" -ne 124 ] || die "the VM did not finish within ${VM_TIMEOUT}s"
	[ "$status" -eq 0 ] || die "qemu exited with status $status"
}

task_fmt() {
	have shfmt || {
		say "shfmt not installed; skipping fmt"
		return 0
	}
	say "Formatting shell sources"
	if [ "$#" -eq 0 ]; then
		shfmt -w scripts tests modules ci/init
		return 0
	fi
	# The hook hands over every staged file; keep only the shell scripts.
	staged_count=$#
	for f in "$@"; do
		case "$f" in *.sh | ci/init) set -- "$@" "$f" ;; esac
	done
	shift "$staged_count"
	[ "$#" -gt 0 ] || return 0
	shfmt -w -- "$@"
}

# checkpatch comes from the newest kernel in ci/kernels. CI fetches it;
# locally it is used once a VM run has fetched that kernel.
task_lint() {
	have shellcheck || die "shellcheck not found. Run: scripts/tasks.sh setup"
	say "Linting shell sources"
	find scripts tests modules -name '*.sh' -exec shellcheck -- ci/init release.sh {} +

	version=$(latest_kernel)
	if [ -n "${CI:-}" ]; then
		src=$(fetch_kernel "$version")
	elif [ -f "$WORK/src/linux-$version/Makefile" ]; then
		src=$WORK/src/linux-$version
	else
		say "linux-$version not fetched yet; skipping checkpatch until 'make vm' has run once"
		return 0
	fi
	say "Running checkpatch from linux-$version"
	# LINUX_VERSION_CODE is the warning for in-tree code that only has to
	# build against itself. An out-of-tree module built against several
	# kernels has to look.
	find modules \( -name '*.c' -o -name '*.h' \) -exec \
		"$src/scripts/checkpatch.pl" --no-tree --strict --quiet --ignore LINUX_VERSION_CODE -f {} +
}

task_test() {
	say "Running tests"
	for t in tests/*.sh; do
		printf '  %s\n' "$t" >&2
		sh "$t"
	done
}

# Builds against the headers of the running kernel, or KDIR.
task_build() {
	kdir=${KDIR:-/lib/modules/$(uname -r)/build}
	[ -f "$kdir/Makefile" ] || die "no kernel build tree at $kdir; install your kernel's headers or set KDIR"
	build_modules "$kdir" "${TOOLCHAIN:-gcc}"
}

task_kernel() {
	build_kernel "${1:-$(latest_kernel)}" "${2:-gcc}" >/dev/null
}

task_vm() {
	version=${1:-$(latest_kernel)}
	toolchain=${2:-gcc}
	build=$(build_kernel "$version" "$toolchain")
	build_modules "$build" "$toolchain"
	out=$WORK/vm/$version-$toolchain
	mkdir -p "$out"
	initramfs=$(make_initramfs "$build" "$toolchain" "$out")
	say "Booting linux-$version ($toolchain)"
	run_vm "$build/arch/x86/boot/bzImage" "$initramfs" "$out"

	expected=$(sed 's/^/kunit:/' "$out/root/kci/kunit")
	for t in "$out"/root/kci/tests/*.sh; do
		[ -f "$t" ] || continue
		t=${t##*/}
		expected="$expected test:${t%.sh}"
	done
	# shellcheck disable=SC2086 # one argument per expected entry
	scripts/check-log.sh "$out/console.log" "$out/results.log" "$TAINT_ALLOWED" $expected
}

task_clean() {
	say "Removing module build output and VM images"
	find modules \( -name '*.o' -o -name '*.ko' -o -name '*.mod' -o -name '*.mod.c' \
		-o -name '.*.cmd' -o -name 'modules.order' -o -name 'Module.symvers' \) -delete
	rm -rf "$WORK/vm"
}

task_setup() {
	have mise || die "mise not found. Install it: https://mise.jdx.dev"
	say "Installing pinned tools"
	mise install
	task_hooks
	say "Ready."
}

task_preflight() {
	task_lint
	task_test
}

task_changelog() {
	say "Regenerating CHANGELOG.md"
	cliff --config cliff.toml --output CHANGELOG.md
}

task_release() {
	[ "$#" -ge 1 ] || die "usage: scripts/tasks.sh release <vX.Y.Z|major|minor|patch>"
	./release.sh "$@"
}

# The tag is the only version this project has.
task_bump_version() { :; }

task_hooks() {
	if [ ! -e .git ]; then
		say "Not a git repository yet; skipping hooks. After 'git init', run: scripts/tasks.sh hooks"
		return 0
	fi
	say "Installing git hooks"
	run_lefthook install
}

task_help() {
	cat <<'USAGE'
Tasks:
  setup        install the pinned tools and the git hooks
  fmt          format shell sources in place
  lint         shellcheck and checkpatch; fails on a problem, changes nothing
  test         run the tests of the scripts themselves
  build        build modules/* against the running kernel's headers (or KDIR)
  kernel [version] [gcc|clang]
               fetch and build one kernel from ci/kernels
  vm [version] [gcc|clang]
               build that kernel and the modules, boot it, run every test
  kernels      list the versions in ci/kernels
  changelog    regenerate CHANGELOG.md from the commit history
  release      cut a release (vX.Y.Z | major | minor | patch)
  preflight    lint + test, as run before a release
  hooks        (re)install the git hooks
  clean        remove module build output and VM images (keeps .kci kernels)
  help         this list

The version defaults to the newest in ci/kernels, the toolchain to gcc.
Through make:
  make vm KERNEL=6.12.118 TOOLCHAIN=clang
  make release V=v1.2.3
USAGE
}

task="${1:-help}"
[ "$#" -gt 0 ] && shift

case "$task" in
	setup) task_setup "$@" ;;
	fmt) task_fmt "$@" ;;
	lint) task_lint "$@" ;;
	test) task_test "$@" ;;
	build) task_build "$@" ;;
	kernel) task_kernel "$@" ;;
	vm) task_vm "$@" ;;
	kernels) kernel_versions ;;
	changelog) task_changelog "$@" ;;
	release) task_release "$@" ;;
	preflight) task_preflight "$@" ;;
	bump-version) task_bump_version "$@" ;;
	hooks) task_hooks "$@" ;;
	clean) task_clean "$@" ;;
	help | -h | --help) task_help ;;
	*) die "unknown task '$task'. Try: scripts/tasks.sh help" ;;
esac

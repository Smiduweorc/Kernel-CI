#!/bin/sh
# Runs inside the test VM under busybox, after the KUnit modules, with
# hello.ko installed but not loaded. A non-zero exit fails the run.
set -eu

fail() {
	echo "$*"
	exit 1
}

modprobe hello
got=$(cat /proc/hello)
[ "$got" = "hello, world" ] || fail "default greeting: $got"
modprobe -r hello
[ ! -e /proc/hello ] || fail "/proc/hello outlived the module"

modprobe hello name=kci repeat=3
got=$(cat /proc/hello)
want=$(printf 'hello, kci\nhello, kci\nhello, kci')
[ "$got" = "$want" ] || fail "greeting with name=kci repeat=3: $got"
got=$(cat /sys/module/hello/parameters/repeat)
[ "$got" = 3 ] || fail "repeat in sysfs: $got"
modprobe -r hello

limit_name=$(printf '%032d' 0)
modprobe hello repeat=16 name="$limit_name"
got=$(wc -l </proc/hello)
[ "$got" -eq 16 ] || fail "repeat=16 gave $got lines"
modprobe -r hello

for args in repeat=0 repeat=17 repeat=abc name= name "name=${limit_name}0"; do
	if modprobe hello "$args"; then
		fail "modprobe hello $args loaded"
	fi
	[ ! -d /sys/module/hello ] || fail "a failed load of hello $args left it in /sys/module"
done

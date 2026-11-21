#!/usr/bin/env sh
# scripts/check-log.sh against hand-written VM logs, one case per way a run
# can fail, each asserting the exit status and the reason given.
set -eu

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# O and N, as scripts/tasks.sh allows them.
allowed=266240
failures=0

console() { cat >"$dir/console.log"; }
results() { cat >"$dir/results.log"; }

# check <description> <want-status> <want-text> [kind:name...]
check() {
	desc=$1
	want_status=$2
	want_text=$3
	shift 3
	status=0
	out=$(scripts/check-log.sh "$dir/console.log" "$dir/results.log" "$allowed" "$@" 2>&1) || status=$?
	if [ "$status" -ne "$want_status" ]; then
		printf 'not ok: %s: exit %s, want %s\n%s\n' "$desc" "$status" "$want_status" "$out" >&2
		failures=$((failures + 1))
	elif ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
		printf 'not ok: %s: output lacks "%s"\n%s\n' "$desc" "$want_text" "$out" >&2
		failures=$((failures + 1))
	fi
}

quiet_console() {
	console <<'EOF'
[    0.000000] Linux version 7.3.5 (gcc)
[    1.204511] hello_kunit: loading out-of-tree module taints kernel.
EOF
}

# The KTAP KUnit prints for one suite, as dmesg shows it.
ktap_pass() {
	cat <<'EOF'
[    1.201000] KTAP version 1
[    1.201001] 1..1
[    1.201002]     KTAP version 1
[    1.201003]     # Subtest: hello
[    1.201004]     # module: hello_kunit
[    1.201005]     1..2
[    1.201006]         KTAP version 1
[    1.201007]         # Subtest: parse_repeat_test
[    1.201008]         ok 1 one is the minimum
[    1.201009]         ok 2 sixteen is the maximum
[    1.201010]     # parse_repeat_test: pass:2 fail:0 skip:0 total:2
[    1.201011]     ok 1 parse_repeat_test
[    1.201012]     ok 2 check_name_test
[    1.201013] # hello: pass:2 fail:0 skip:0 total:2
[    1.201014] ok 1 hello
EOF
}

passing_results() {
	{
		echo "kci: begin kunit hello_kunit"
		ktap_pass
		echo "kci: end 0"
		echo "kci: begin test hello"
		echo "kci: end 0"
		echo "kci: tainted 266240"
		echo "kci: done"
	} | results
}

quiet_console
passing_results
check "a clean run passes" 0 "pass kunit hello_kunit" kunit:hello_kunit test:hello
check "a clean run reports the test too" 0 "pass test hello" kunit:hello_kunit test:hello

quiet_console
passing_results
sed 's/$/\r/' "$dir/results.log" >"$dir/crlf" && mv "$dir/crlf" "$dir/results.log"
check "CRLF from the serial line is accepted" 0 "pass test hello" kunit:hello_kunit test:hello

quiet_console
passing_results
sed 's/^kci: tainted .*/kci: tainted 0/' "$dir/results.log" >"$dir/t" && mv "$dir/t" "$dir/results.log"
check "an untainted kernel passes" 0 "pass test hello" kunit:hello_kunit test:hello

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	ktap_pass | sed 's/ok 2 sixteen is the maximum/ok 2 sixteen is the maximum # SKIP no reason/'
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a skipped case is a pass, as KUnit counts it" 0 "pass kunit hello_kunit" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	ktap_pass | sed 's/        ok 2 sixteen/        not ok 2 sixteen/; s/    ok 1 parse_repeat_test/    not ok 1 parse_repeat_test/; s/] ok 1 hello/] not ok 1 hello/'
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a failing KUnit case fails the run" 1 "3 KTAP results are not ok" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	ktap_pass | sed 's/        ok 2 sixteen/        not ok 2 sixteen/'
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a nested not ok fails even when the suite line says ok" 1 "1 KTAP results are not ok" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	ktap_pass | sed 's/] 1\.\.1$/] 1..2/'
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a suite missing from the report fails" 1 "planned 2 suites but reported 1" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	ktap_pass | grep -v '] ok 1 hello$'
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a suite that never reports its result fails" 1 "planned 1 suites but reported 0" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	echo "[    1.200000] hello_kunit: loading out-of-tree module taints kernel."
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a KUnit module that prints no KTAP fails" 1 "printed no KTAP plan" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	echo "[    1.201001] 1..0"
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a KTAP plan of zero suites fails" 1 "printed no KTAP plan" kunit:hello_kunit

quiet_console
{
	echo "kci: begin kunit hello_kunit"
	echo "modprobe: can't load module hello_kunit: Unknown symbol in module"
	echo "kci: end 1"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a KUnit module that fails to load fails" 1 "FAIL kunit hello_kunit: exited with status 1" kunit:hello_kunit
check "a failure shows the entry's output" 1 "Unknown symbol in module" kunit:hello_kunit

quiet_console
{
	echo "kci: begin test hello"
	echo "default greeting: hello, nobody"
	echo "kci: end 1"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "a failing test.sh fails the run" 1 "FAIL test hello: exited with status 1" test:hello
check "a failing test.sh shows its output" 1 "    default greeting: hello, nobody" test:hello

quiet_console
passing_results
check "an expected entry that never ran fails" 1 "FAIL test:other: never ran" kunit:hello_kunit test:hello test:other

quiet_console
passing_results
check "an entry nobody expected fails" 1 "FAIL test:hello: ran but was not expected" kunit:hello_kunit

quiet_console
{
	echo "kci: begin test hello"
	echo "kci: end 0"
	echo "kci: begin test hello"
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "an entry that ran twice fails" 1 "FAIL test:hello: ran 2 times" test:hello

quiet_console
{
	echo "kci: begin test hello"
	echo "kci: begin test other"
	echo "kci: end 0"
	echo "kci: tainted 266240"
	echo "kci: done"
} | results
check "an entry cut off by the next one fails" 1 "FAIL test hello: has no end line" test:hello test:other

quiet_console
{
	echo "kci: begin test hello"
	echo "partial output"
} | results
check "a run cut off mid-entry fails" 1 "FAIL test hello: has no end line" test:hello
check "a run cut off mid-entry never reached done" 1 "FAIL ci/init never reached kci: done" test:hello

quiet_console
passing_results
grep -v '^kci: done$' "$dir/results.log" >"$dir/t" && mv "$dir/t" "$dir/results.log"
check "a run without kci: done fails" 1 "FAIL ci/init never reached kci: done" kunit:hello_kunit test:hello

quiet_console
passing_results
grep -v '^kci: tainted' "$dir/results.log" >"$dir/t" && mv "$dir/t" "$dir/results.log"
check "a run without the taint mask fails" 1 "FAIL ci/init never reported the taint mask" kunit:hello_kunit test:hello

quiet_console
passing_results
sed 's/^kci: tainted .*/kci: tainted 266752/' "$dir/results.log" >"$dir/t" && mv "$dir/t" "$dir/results.log"
check "a taint bit outside O and N fails (W, a warning was issued)" 1 "the kernel is tainted (266752" kunit:hello_kunit test:hello

passing_results
console <<'EOF'
[    1.300000] ==================================================================
[    1.300001] BUG: KASAN: slab-out-of-bounds in hello_show+0x42/0x80 [hello]
EOF
check "a KASAN report on the console fails" 1 "BUG: KASAN: slab-out-of-bounds" kunit:hello_kunit test:hello

passing_results
console <<'EOF'
[    1.300000] WARNING: CPU: 1 PID: 93 at hello.c:50 hello_init+0x1/0x2 [hello]
EOF
check "a WARN on the console fails" 1 "WARNING: CPU: 1 PID: 93" kunit:hello_kunit test:hello

passing_results
console <<'EOF'
[    1.300000] UBSAN: shift-out-of-bounds in hello.c:12:5
EOF
check "a UBSAN report on the console fails" 1 "UBSAN: shift-out-of-bounds" kunit:hello_kunit test:hello

passing_results
console <<'EOF'
[    1.300000] Kernel panic - not syncing: panic_on_warn set ...
EOF
check "a panic on the console fails" 1 "Kernel panic - not syncing" kunit:hello_kunit test:hello

passing_results
console <<'EOF'
[   21.000000] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
EOF
check "an RCU stall on the console fails" 1 "detected stalls" kunit:hello_kunit test:hello

passing_results
rm -f "$dir/console.log"
check "a missing console log fails" 1 "no console log" kunit:hello_kunit test:hello

quiet_console
rm -f "$dir/results.log"
check "a missing results log fails" 1 "the VM never started ci/init" kunit:hello_kunit test:hello

status=0
scripts/check-log.sh "$dir/console.log" "$dir/results.log" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 2 ]; then
	echo "not ok: too few arguments: exit $status, want 2" >&2
	failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || {
	echo "$failures check-log cases failed" >&2
	exit 1
}

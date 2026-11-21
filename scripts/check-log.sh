#!/usr/bin/env sh
#
# Decides whether a test VM run passed, from the kernel console (ttyS0) and
# the results that ci/init wrote to ttyS1.
#
# Usage: scripts/check-log.sh <console.log> <results.log> <allowed-taint> <kind:name>...
#   kind:name is kunit:<module> or test:<module>, one per entry expected.
#
# The run passes when all of these hold:
#   - every expected entry ran exactly once, and nothing else ran
#   - every entry ended with status 0
#   - every KUnit entry printed a KTAP plan of at least one suite, a result
#     for each planned suite, and no "not ok" at any depth (a skip is a pass,
#     as KUnit counts it)
#   - ci/init reached "kci: done", and the taint mask has no bit outside
#     <allowed-taint>
#   - the console shows no BUG, WARNING, oops, panic, sanitizer report,
#     stall or hung task
#
# Prints one line per entry, with its output under any that failed.

set -eu

[ "$#" -ge 3 ] || {
	echo "usage: scripts/check-log.sh <console.log> <results.log> <allowed-taint> <kind:name>..." >&2
	exit 2
}
console=$1
results=$2
allowed=$3
shift 3

failed=0
fail() {
	printf 'FAIL %s\n' "$*"
	failed=1
}

if [ ! -f "$results" ]; then
	fail "no results: $results does not exist, so the VM never started ci/init"
	exit 1
fi

# awk owns the entries and prints "tainted <mask>" last, or nothing if the
# line is missing. The taint arithmetic needs bitwise operators, which POSIX
# awk does not have, so it happens below.
summary=$(awk -v expected="$*" '
function strip(s) {
	sub(/^\[ *[0-9]+\.[0-9]+\] /, "", s)
	return s
}
function report(problem) {
	if (problem == "")
		printf "pass %s %s\n", kind, name
	else {
		printf "FAIL %s %s: %s\n", kind, name, problem
		printf "%s", body
		bad = 1
	}
}
function finish(status,    problem) {
	problem = ""
	if (status != "0")
		problem = "exited with status " status
	else if (kind == "kunit") {
		if (plan < 1)
			problem = "printed no KTAP plan"
		else if (results != plan)
			problem = "planned " plan " suites but reported " results
		else if (notok > 0)
			problem = notok " KTAP results are not ok"
	}
	report(problem)
}
BEGIN {
	n = split(expected, e, " ")
	for (i = 1; i <= n; i++)
		want[e[i]] = 1
}
# A serial tty turns every newline into CRLF.
{ sub(/\r$/, "") }
/^kci: begin (kunit|test) [^ ]+$/ {
	if (current != "")
		report("has no end line")
	kind = $3
	name = $4
	current = kind ":" name
	ran[current]++
	plan = 0
	results = 0
	notok = 0
	body = ""
	next
}
/^kci: end -?[0-9]+$/ && current != "" {
	finish($3)
	current = ""
	next
}
/^kci: tainted [0-9]+$/ { tainted = $3; next }
/^kci: done$/ { done = 1; next }
current != "" {
	body = body "    " $0 "\n"
	if (kind != "kunit")
		next
	line = strip($0)
	if (plan == 0 && line ~ /^1\.\.[0-9]+$/)
		plan = substr(line, 4) + 0
	else if (line ~ /^(not )?ok [0-9]+( |$)/) {
		results++
		if (line ~ /^not ok/)
			notok++
	} else if (line ~ /^[ \t]+not ok [0-9]+( |$)/)
		notok++
}
END {
	if (current != "")
		report("has no end line")
	for (entry in ran) {
		if (!(entry in want)) {
			print "FAIL " entry ": ran but was not expected"
			bad = 1
		} else if (ran[entry] > 1) {
			print "FAIL " entry ": ran " ran[entry] " times"
			bad = 1
		}
	}
	for (entry in want) {
		if (!(entry in ran)) {
			print "FAIL " entry ": never ran"
			bad = 1
		}
	}
	if (!done) {
		print "FAIL ci/init never reached kci: done"
		bad = 1
	}
	if (tainted != "")
		print "tainted " tainted
	exit bad
}
' "$results") || failed=1

printf '%s\n' "$summary" | grep -v '^tainted ' || true

tainted=$(printf '%s\n' "$summary" | sed -n 's/^tainted //p')
if [ -z "$tainted" ]; then
	fail "ci/init never reported the taint mask"
elif [ $((tainted & ~allowed)) -ne 0 ]; then
	fail "the kernel is tainted ($tainted; allowed bits $allowed)"
fi

if [ -f "$console" ]; then
	splats=$(grep -E 'BUG:|WARNING:|Oops|Kernel panic|kernel BUG at|UBSAN:|general protection fault|Call Trace:|detected stalls|blocked for more than' "$console" || true)
	if [ -n "$splats" ]; then
		fail "the kernel console reports a problem:"
		printf '%s\n' "$splats" | sed 's/^/    /'
	fi
else
	fail "no console log: $console does not exist"
fi

exit "$failed"

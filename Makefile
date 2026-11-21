# Thin dispatcher over scripts/tasks.sh, which is where the tasks are actually
# defined. Keeping the logic there means `make vm`, the git hooks and CI all
# run the identical command.

.DEFAULT_GOAL := help

TASKS := setup fmt lint test build kernels changelog preflight hooks clean help

.PHONY: $(TASKS) kernel vm release

$(TASKS):
	@scripts/tasks.sh $@

# make vm KERNEL=6.12.118 TOOLCHAIN=clang   (both optional)
kernel vm:
	@scripts/tasks.sh $@ $(KERNEL) $(TOOLCHAIN)

# make release V=v1.2.3   (or V=patch | minor | major)
release:
	@test -n "$(V)" || { echo "usage: make release V=<vX.Y.Z|major|minor|patch>" >&2; exit 1; }
	@scripts/tasks.sh release $(V)

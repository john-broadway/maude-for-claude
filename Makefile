.PHONY: test test-py verify lint release smoke mac-shape

test-py:
	@if command -v pytest >/dev/null 2>&1; then PYTHONPATH=. pytest tests/vault tests/eye tests/tape tests/marker tests/rules -q; \
	else echo "pytest not installed — skipping python vault tests"; fi

test: test-py
	bash tests/run.sh

# Propagate a new version everywhere + stamp dates + run the gate. Writes no prose.
# Usage: make release VERSION=0.9.1
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.9.1"; exit 2; }
	bash scripts/release.sh "$(VERSION)"

verify:
	bash scripts/maude-verify.sh

# The prove-it-real gate: stage a git-archive of HEAD (the shape a stranger
# installs) and prove it validates, passes its own fleet, and greets cold.
smoke:
	bash scripts/install-smoke.sh

# The full suite in a macOS-shaped userland (no flock, BSD awk, slow forks, macOS TMPDIR).
# The public macOS leg only runs on a public PR; this runs it here first. --check proves
# the shape without running anything.
mac-shape:
	bash scripts/mac-shape.sh

# Lint all shell with shellcheck, gated at warning severity (see .shellcheckrc
# for the source-following + the one intentional test-idiom disable).
lint:
	shellcheck --severity=warning hooks/scripts/*.sh scripts/*.sh tests/*.sh

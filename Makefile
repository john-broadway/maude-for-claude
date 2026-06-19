.PHONY: test verify lint release

test:
	bash tests/run.sh

# Propagate a new version everywhere + stamp dates + run the gate. Writes no prose.
# Usage: make release VERSION=0.9.1
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.9.1"; exit 2; }
	bash scripts/release.sh "$(VERSION)"

verify:
	bash scripts/maude-verify.sh

# Lint all shell with shellcheck, gated at warning severity (see .shellcheckrc
# for the source-following + the one intentional test-idiom disable).
lint:
	shellcheck --severity=warning hooks/scripts/*.sh scripts/*.sh tests/*.sh

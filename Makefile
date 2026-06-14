.PHONY: test verify lint

test:
	bash tests/run.sh

verify:
	bash scripts/maude-verify.sh

# Lint all shell with shellcheck, gated at warning severity (see .shellcheckrc
# for the source-following + the one intentional test-idiom disable).
lint:
	shellcheck --severity=warning hooks/scripts/*.sh scripts/*.sh tests/*.sh

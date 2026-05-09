.PHONY: scrub test verify

scrub:
	bash scripts/scrub-check.sh

test:
	bash tests/run.sh

verify:
	bash scripts/maude-verify.sh

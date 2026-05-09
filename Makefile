.PHONY: test verify

test:
	bash tests/run.sh

verify:
	bash scripts/maude-verify.sh

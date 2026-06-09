# Clean fixture

A minimal, valid plugin tree used by `tests/test-verify.sh` to assert that a
clean project yields **zero** findings from `scripts/maude-verify.sh`.

Intentionally has no "What's new" section, no relative links, and no dated
headers, so verify stays green over time rather than depending on transient
state (the bug that made the old test assert against the live repo).

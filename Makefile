.PHONY: all lint scrub test test-cov clean install install-core

all: lint scrub test

scrub:
	bash scripts/scrub-check.sh

lint:
	ruff check src/ tests/

test:
	pytest tests/ -v

test-cov:
	pytest tests/ --cov=src/maude --cov-report=term-missing

clean:
	find . -name __pycache__ -exec rm -rf {} +
	rm -rf dist/ build/ *.egg-info .pytest_cache htmlcov

install:
	pip install -e ".[all,dev]"

install-core:
	pip install -e .

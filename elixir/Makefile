.PHONY: help all setup deps build fmt fmt-check lint test coverage type-check workflow-check ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

# A full recompile on purpose: the type checker only reports on files it compiles, so an
# incremental build hides type problems in everything that did not change. Warnings are errors
# here -- that is the whole point of the step -- and dependencies are exempt (their warnings are
# not ours to fix; mint's deprecated xref option is the current example).
type-check:
	$(MIX) compile --force --warnings-as-errors

# The tracker's token only has to be present for this to validate the file -- nothing is called --
# so a placeholder keeps the step runnable in CI without a secret.
workflow-check:
	GITHUB_TOKEN=workflow-check $(MIX) workflow.check

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) type-check
	$(MAKE) workflow-check
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci

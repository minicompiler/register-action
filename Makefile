# Makefile -- the gate of minicompiler/register-action.
#
# There is nothing to build here: the action is `action.yml` and one shell
# script. `make check` is what has to be green before a push, and it is what
# .github/workflows/check.yml runs.
#
#   make check      shellcheck (when it is installed) + sh -n + test/run.sh
#   make lint       just the two static checks
#   make test       just the run against test/stub.py

SCRIPTS = register.sh test/run.sh

.PHONY: check lint test

check: lint test

lint:
	@for f in $(SCRIPTS); do sh -n $$f && echo "sh -n  $$f ok"; done
	@if command -v shellcheck > /dev/null 2>&1; then \
	    shellcheck -s sh $(SCRIPTS) && echo "shellcheck ok"; \
	else \
	    echo "shellcheck: SKIPPED (not installed)"; \
	fi
	@python3 -c "import ast,sys; ast.parse(open('test/stub.py').read())" \
	    && echo "python -m ast  test/stub.py ok"

test:
	sh test/run.sh

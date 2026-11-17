# rex-develop's development tasks. `just` lists them.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the tasks
default:
    @just --list --unsorted

# The unit tests: no Rex, no network
test:
    for t in tests/rules.lua tests/decisions.lua tests/plan.lua tests/trackers.lua; do luajit "$t"; done

# The end-to-end test in Rex, answering through the CLI
e2e:
    tests/e2e.sh

# The end-to-end test, answering through a rex-inbox hub of its own: just e2e-inbox ~/src/rex-inbox/target/debug/rex-inbox
e2e-inbox bin="rex-inbox":
    INBOX=1 REX_INBOX_BIN={{ bin }} tests/e2e.sh

# Syntax: every Lua file compiles, every script parses
lint:
    for f in $(find lua scripts init.lua tests -name '*.lua'); do luajit -bl "$f" >/dev/null; done
    bash -n bin/rex-develop tests/e2e.sh tests/fake-agent.sh tests/bin/gh
    python3 -c 'import ast,sys; ast.parse(open("tests/fake-linear.py").read())'

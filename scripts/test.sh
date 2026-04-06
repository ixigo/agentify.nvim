#!/usr/bin/env sh
set -eu

nvim --headless -u tests/minimal_init.lua "+lua require('tests.runner').run()"


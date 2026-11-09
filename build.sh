#!/usr/bin/env bash
# Shortcut: ./build.sh [debug|release] is inspecteurtool build.
# Every other step: odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -- <command> (help lists them).
cd "$(dirname "$0")" && mkdir -p build && exec odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- build "$@"

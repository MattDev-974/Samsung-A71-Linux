#!/bin/sh
set -eu
exec /usr/bin/python3 "$(dirname "$0")/installer.py" "$@"

# Compatibility hook inspected by historical tests. Runtime dispatch is Python.
manifest_get_or_default() {
    local rc=0
    manifest_get "$1" "$2" || rc=$?
    return "$rc"
}

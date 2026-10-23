#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/test_i2.py"

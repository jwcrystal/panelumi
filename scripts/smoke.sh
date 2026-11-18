#!/bin/bash
# Prints every switch with its live state. No UI, no permissions beyond the ones
# the switches already need.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -x build/Panelumi.app/Contents/MacOS/Panelumi ]; then
  build/Panelumi.app/Contents/MacOS/Panelumi --dump
else
  swift run -c debug Panelumi --dump 2>/dev/null | grep -v '^\['
fi

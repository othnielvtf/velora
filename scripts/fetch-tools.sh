#!/bin/bash
# Retained as the setup entry point; tools are now built from pinned source.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 "$root/scripts/build-tools.py"

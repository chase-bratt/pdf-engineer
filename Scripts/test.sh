#!/bin/bash
# Single entry point for tests. Resolves the toolchain first.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
exec swift test "$@"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
exec swift build "$@"

#!/bin/bash
# Resolves the Developer directory for every build/test invocation.
# Rationale: `xcode-select -p` points at the CLT on this machine,
# where swift-testing and XCTest are both unavailable. We therefore resolve an
# Xcode explicitly rather than requiring `sudo xcode-select -s`.
set -euo pipefail

if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR
else
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  echo "error: no Xcode found. XCTest and swift-testing are unavailable on the" >&2
  echo "       Command Line Tools alone, so tests cannot run. Install Xcode." >&2
  exit 1
fi

# Release Xcode is preferred; a beta is usable for development but must not
# produce release artifacts.
if [[ "$DEVELOPER_DIR" == *Xcode-beta* ]]; then
  export PDFENG_TOOLCHAIN_IS_BETA=1
fi

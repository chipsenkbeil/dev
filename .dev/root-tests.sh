#!/usr/bin/env bash
# group: Check your work
# hidden
# Run dev's root-safety and tools tests as real root on Linux through ci (about a minute).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

no_args

exec ci run bootstrap --local --job root-tests -f

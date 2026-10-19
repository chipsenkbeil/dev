#!/usr/bin/env bash
# Report tool availability from tools.tsv, and exit 1 when a tool is missing.
# flags: --manifest
#
# Arguments pass to scripts/pkg.sh check (--manifest FILE).
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bash scripts/pkg.sh check ${ARGS[@]+"${ARGS[@]}"}

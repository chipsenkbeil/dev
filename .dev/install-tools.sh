#!/usr/bin/env bash
# Install all manifest tools via the OS package manager. DRY_RUN=1 for dry-run.
# usage: install-tools.sh [DRY_RUN=1] [name...]
set -eo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

split_vars "$@"
bash scripts/pkg.sh install ${DRY_RUN:+--dry-run} ${ARGS[@]+"${ARGS[@]}"}

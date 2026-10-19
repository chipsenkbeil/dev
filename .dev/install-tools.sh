#!/usr/bin/env bash
# Install all manifest tools via the OS package manager. DRY_RUN=1 for dry-run.
# flags: --manifest --log-file --dry-run
# usage: install-tools.sh [DRY_RUN=1] [name...]
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dry_run=()
if truthy "${DRY_RUN:-}"; then dry_run=(--dry-run); fi
bash scripts/pkg.sh install ${dry_run[@]+"${dry_run[@]}"} ${ARGS[@]+"${ARGS[@]}"}

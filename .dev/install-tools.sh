#!/usr/bin/env bash
# Install all manifest tools via the OS package manager. DRY_RUN=1 for dry-run.
# FORCE=1 reinstalls the named tools even when they are already present.
# flags: --manifest --log-file --dry-run --force
# usage: install-tools.sh [DRY_RUN=1] [FORCE=1] [name...]
set -eo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

opts=()
if truthy "${DRY_RUN:-}"; then opts+=(--dry-run); fi
if truthy "${FORCE:-}"; then opts+=(--force); fi
bash scripts/pkg.sh install ${opts[@]+"${opts[@]}"} ${ARGS[@]+"${ARGS[@]}"}

#!/usr/bin/env bash
# Report tool availability from tools.tsv. Arguments pass to scripts/pkg.sh check
# (--manifest FILE).
set -eo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bash scripts/pkg.sh check "$@"

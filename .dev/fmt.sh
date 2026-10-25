#!/usr/bin/env bash
# Format the Lua roots with stylua, using the config that dev lint checks against.
# flags:
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

no_args

collect_lua_files

if [ "${#LUA_FILES[@]}" -eq 0 ]; then
    exit 0
fi
if ! command -v stylua >/dev/null 2>&1; then
    die "stylua not found. Install with: brew install stylua"
fi
stylua --config-path "$LUA_LINT_DIR/stylua.toml" "${LUA_FILES[@]}"

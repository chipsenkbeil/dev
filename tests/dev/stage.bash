# shellcheck shell=bash

stage_share() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    mkdir -p "$1"
    cp -R "$root/main.lua" "$root/pkg.lua" "$root/VERSION" "$root/xtrace.bash" "$root/lua" "$root/docs" "$root/init" "$root/board" "$1/"
}

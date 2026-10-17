#!/usr/bin/env bash
# scripts/pkg/script.sh — cross-OS `script:` handler. Defines pkg_install for
# `script:` cells. Source, do not execute.
#
# SECURITY MODEL
#   A `script:` cell runs code fetched from the exact source named in the
#   manifest. Listing a `script:` cell is the (hand-editing) author's explicit
#   authorization to execute that code — the same trust model as a brew `tap:`.
#   For URLs we download-then-run (NOT pipe-to-shell) so the payload lands as a
#   real file we could inspect, and dry-run prints the URL so the source is
#   visible before anything executes. No self-elevation is done here: an
#   installer that needs root prompts for it itself.
#
# ARGUMENTS
#   Arguments are supported via a double-quoted cell. Because the manifest is
#   whitespace-delimited, a `script:` cell that needs arguments must be wrapped
#   in double quotes so the tokenizer keeps it as one field, e.g.
#     "script:/tmp/x.sh --flag value"  or  "script:https://h/x.sh --flag value"
#   The first token is the local path or http(s):// URL; the remainder are
#   passed through to the script (`bash <script> <args>`).

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Run <package> unless <binary> is already on PATH. <package> is a local
#   script path or an http(s):// URL, optionally followed by space-separated
#   arguments (see ARGUMENTS). <channel>/<repo> are unused (uniform signature).
pkg_install() {
    local name="$1" binary="$2" package="$3" dry_run="$6"

    if [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    fi

    # Split the cell into the source (first token) and any pass-through args.
    local src="${package%% *}" args=""
    [ "$src" != "$package" ] && args="${package#* }"

    case "$src" in
    http://* | https://*)
        # Remote installer: fetch to a temp file, then execute it with args.
        if [ "$dry_run" = "1" ]; then
            printf '  + %s (dry-run):\n      curl -fsSL %s -o /tmp/%s-install.sh && bash /tmp/%s-install.sh%s\n' \
                "$name" "$src" "$name" "$name" "${args:+ $args}"
            return 0
        fi
        if ! command -v curl >/dev/null 2>&1; then
            printf '  ! %s: curl is required to fetch %s\n' "$name" "$src" >&2
            return 1
        fi
        printf '  + installing %s (script: %s)...\n' "$name" "$src"
        local tmp
        tmp="$(mktemp)"
        if ! pkg_run "curl -fsSL $src -o $tmp"; then
            printf '  ! %s: failed to download %s\n' "$name" "$src" >&2
            rm -f "$tmp"
            return 1
        fi
        pkg_run "bash $tmp $args"
        local rc=$?
        rm -f "$tmp"
        return $rc
        ;;
    *)
        # Local script path.
        if [ "$dry_run" = "1" ]; then
            printf '  + %s (dry-run):\n      bash %s%s\n' "$name" "$src" "${args:+ $args}"
            return 0
        fi
        printf '  + installing %s (script: %s)...\n' "$name" "$src"
        pkg_run "bash $src $args"
        ;;
    esac
}

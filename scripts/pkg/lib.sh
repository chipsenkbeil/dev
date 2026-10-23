#!/usr/bin/env bash
# scripts/pkg/lib.sh — manifest + cell parsing helpers shared by the pkg.sh
# dispatcher, the package drivers, and the tests. Pure functions: no side
# effects, safe to source and unit-test.

# parse_cell <cell>
#   Parse a manager cell: [channel:]package[,repo:owner/project][,bin:override]
#   Prints TAB-separated: channel<TAB>package<TAB>repo<TAB>bin (empty fields
#   left empty). Returns 1 and prints nothing if the cell is "-" (N/A here).
parse_cell() {
    local cell="$1"
    local channel="" package="" repo="" bin=""
    [ "$cell" = "-" ] && return 1

    local IFS=','
    local segs
    read -r -a segs <<<"$cell"

    local head="${segs[0]}"
    if [ "${head#*:}" != "$head" ]; then
        channel="${head%%:*}"
        package="${head#*:}"
    else
        package="$head"
    fi

    local i seg
    for ((i = 1; i < ${#segs[@]}; i++)); do
        seg="${segs[i]}"
        case "$seg" in
        repo:*) repo="${seg#repo:}" ;;
        bin:*) bin="${seg#bin:}" ;;
        esac
    done

    printf '%s\t%s\t%s\t%s\n' "$channel" "$package" "$repo" "$bin"
}

# split_cell <parsed>
#   <parsed> is parse_cell output: channel<TAB>package<TAB>repo<TAB>bin.
#   Sets PC_CHANNEL, PC_PACKAGE, PC_REPO, PC_BIN. Uses parameter expansion, NOT
#   `read`: tab is IFS-whitespace, so `IFS=$'\t' read` drops leading/interior empty
#   fields on bash 3.2, corrupting bare and bare+bin cells.
split_cell() {
    local p="$1"

    # shellcheck disable=SC2034
    PC_CHANNEL="${p%%$'\t'*}"
    p="${p#*$'\t'}"

    # shellcheck disable=SC2034
    PC_PACKAGE="${p%%$'\t'*}"
    p="${p#*$'\t'}"

    # shellcheck disable=SC2034
    PC_REPO="${p%%$'\t'*}"

    # shellcheck disable=SC2034
    PC_BIN="${p#*$'\t'}"
}

# resolve_binary <default_binary> <override>
#   Print the effective command name to probe: the override if non-empty,
#   otherwise the default from the manifest's `binary` column.
resolve_binary() {
    if [ -n "$2" ]; then
        printf '%s\n' "$2"
    else
        printf '%s\n' "$1"
    fi
}

# detect_primary_manager
#   Print the primary package manager for this OS, or nothing if unsupported.
detect_primary_manager() {
    case "$(uname)" in
    Darwin) printf 'brew\n' ;;
    Linux)
        if command -v pacman >/dev/null 2>&1; then
            printf 'pacman\n'
        elif command -v dnf >/dev/null 2>&1; then
            printf 'dnf\n'
        elif command -v apt-get >/dev/null 2>&1; then
            printf 'apt\n'
        fi
        ;;
    esac
}

# _MANIFEST_AWK_TOKENIZER — awk source defining tok(line, arr): a QUOTE-AWARE
#   field splitter. A double-quoted "..." span is a single field with the
#   surrounding quotes stripped (so a cell may contain spaces, e.g. a script:
#   cell with arguments); every unquoted field splits on runs of spaces/tabs
#   exactly as awk's default. Returns the field count; fields land in arr[1..n].
#   Walks the line char-by-char so behavior is identical across BSD/gawk/mawk.
_MANIFEST_AWK_TOKENIZER='
function tok(line, arr,   n, i, c, cur, inq, has) {
    n = 0; cur = ""; inq = 0; has = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") inq = 0; else cur = cur c
        } else if (c == "\"") {
            inq = 1; has = 1
        } else if (c == " " || c == "\t") {
            if (has) { arr[++n] = cur; cur = ""; has = 0 }
        } else {
            cur = cur c; has = 1
        }
    }
    if (has) arr[++n] = cur
    return n
}
'

# _MANIFEST_AWK_EXPAND — awk source defining the manifest variable layer, applied
#   AFTER quote-aware tokenization (see the design):
#     parse_env(line)     parse a `# @env NAME value` / `# @env NAME "quoted"`
#                         comment into defaults[NAME] (value is quote-aware).
#     resolve(nm, row)    ENVIRON override -> defaults default -> error+exit 1.
#     expand(s, row)      one-pass walk: $$ -> literal $; ${NAME} / $NAME
#                         (bare name = [A-Za-z0-9_]+) -> resolved value; a lone
#                         $ not followed by a name char, { or $ stays literal.
#   Substitution is literal text — never eval'd or shell-expanded. Undefined
#   references abort (exit 1) with a message on /dev/stderr.
# shellcheck disable=SC2016  # awk source: the $ chars are awk/text, not shell
_MANIFEST_AWK_EXPAND='
function parse_env(line,   name, rest, val, q) {
    sub(/^[[:space:]]*#[[:space:]]*@env[[:space:]]+/, "", line)
    if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*/)) return
    name = substr(line, 1, RLENGTH)
    rest = substr(line, RLENGTH + 1)
    sub(/^[[:space:]]+/, "", rest)
    if (substr(rest, 1, 1) == "\"") {
        rest = substr(rest, 2)
        q = index(rest, "\"")
        val = (q > 0) ? substr(rest, 1, q - 1) : rest
    } else if (match(rest, /^[^[:space:]]+/)) {
        val = substr(rest, 1, RLENGTH)
    } else {
        val = ""
    }
    defaults[name] = val
}
function resolve(nm, row) {
    if (nm in ENVIRON) return ENVIRON[nm]
    if (nm in defaults) return defaults[nm]
    printf "manifest: error: undefined variable ${%s} (row: %s)\n", nm, row > "/dev/stderr"
    exit 1
}
function expand(s, row,   out, i, slen, ch, nxt, j, nm, k, cc) {
    out = ""; i = 1; slen = length(s)
    while (i <= slen) {
        ch = substr(s, i, 1)
        if (ch != "$") { out = out ch; i++; continue }
        nxt = substr(s, i + 1, 1)
        if (nxt == "$") { out = out "$"; i += 2; continue }
        if (nxt == "{") {
            j = index(substr(s, i + 2), "}")
            if (j > 0) {
                nm = substr(s, i + 2, j - 1)
                if (nm ~ /^[A-Za-z0-9_]+$/) {
                    out = out resolve(nm, row)
                    i = i + 2 + j
                    continue
                }
            }
            out = out "$"; i++; continue
        }
        if (nxt ~ /[A-Za-z0-9_]/) {
            nm = ""; k = i + 1
            while (k <= slen) {
                cc = substr(s, k, 1)
                if (cc ~ /[A-Za-z0-9_]/) { nm = nm cc; k++ } else break
            }
            out = out resolve(nm, row)
            i = k
            continue
        }
        out = out "$"; i++
    }
    return out
}
'

# manifest_column_index <manifest> <manager>
#   Print the 1-based field index of <manager> in the header (first
#   non-comment, non-blank line). Manager columns start at field 3.
manifest_column_index() {
    local manifest="$1" manager="$2"
    awk -v m="$manager" "$_MANIFEST_AWK_TOKENIZER"'
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { n = tok($0, f); for (i = 3; i <= n; i++) if (f[i] == m && m != "groups") print i; exit }
    ' "$manifest"
}

# manifest_rows <manifest> <col> [group]
#   Print each data row as: name<TAB>binary<TAB>cell (cell = field <col>),
#   skipping comments, blanks, and the header row. `# @env NAME value` header
#   comments define variable defaults; cell $NAME / ${NAME} references are then
#   expanded (ENVIRON override -> @env default -> error). Rows are buffered and
#   expanded in END so an undefined reference aborts (exit 1, message on stderr)
#   BEFORE any row is printed — never partial output. With <group>, only rows
#   whose `groups` column lists it are printed, so a manifest with no such
#   column prints nothing.
manifest_rows() {
    local manifest="$1" col="$2" group="${3:-}"
    awk -v c="$col" -v g="$group" "$_MANIFEST_AWK_TOKENIZER$_MANIFEST_AWK_EXPAND"'
        /^[[:space:]]*#[[:space:]]*@env[[:space:]]/ { parse_env($0); next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        !seen_header {
            seen_header = 1
            n = tok($0, f)
            for (i = 3; i <= n; i++) if (f[i] == "groups") gi = i
            next
        }
        {
            n = tok($0, f)
            if (g != "") {
                if (!gi) next
                ng = split(f[gi], gl, ",")
                hit = 0
                for (k = 1; k <= ng; k++) if (gl[k] == g) hit = 1
                if (!hit) next
            }
            nrows++
            b1[nrows] = f[1]; b2[nrows] = f[2]; b3[nrows] = f[c]
        }
        END {
            for (r = 1; r <= nrows; r++) {
                o1[r] = expand(b1[r], b1[r])
                o2[r] = expand(b2[r], b1[r])
                o3[r] = expand(b3[r], b1[r])
            }
            for (r = 1; r <= nrows; r++)
                print o1[r] "\t" o2[r] "\t" o3[r]
        }
    ' "$manifest"
}

# pkg_run <command-string>
#   Run a (word-split) command, sending its stdout+stderr to $PKG_LOG_FILE
#   (appended) when that global is set, else to the terminal. Returns the
#   command's exit status. Mirrors helpers.sh exec_and_log so installer output
#   goes to the log, not the screen.
pkg_run() {
    if [ -n "${PKG_LOG_FILE:-}" ]; then
        # shellcheck disable=SC2086
        $1 >>"$PKG_LOG_FILE" 2>&1
    else
        # shellcheck disable=SC2086
        $1
    fi
}

# channel_scope <channel>
#   Who installs a cell: system (the official package manager, run as root),
#   user (script:, cargo: and flatpak:, which write into the running user's
#   home), or third_party (aur:, copr: and luarocks: run code from a repo that is
#   not the distribution's own, so a box never installs them as root).
channel_scope() {
    case "$1" in
    cargo | flatpak | script) printf 'user\n' ;;
    aur | copr | luarocks) printf 'third_party\n' ;;
    *) printf 'system\n' ;;
    esac
}

# valid_package <channel> <package> <repo>
#   Succeed when the package name (and repo, when set) is a plain word, so a
#   manifest cell can never inject an option or a second argument into the
#   command a driver builds. A script: cell is a path or URL and is exempt.
valid_package() {
    [ "$1" = script ] && return 0
    [[ "$2" =~ ^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$ ]] || return 1
    [ -z "$3" ] || [[ "$3" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

# channel_handler <channel> <primary_manager>
#   Which driver handles a cell. Cross-OS channels (cargo, flatpak, luarocks,
#   script) use their own handler regardless of OS; everything else (bare, cask,
#   tap, aur, copr) uses the OS's primary manager.
channel_handler() {
    case "$1" in
    cargo | flatpak | luarocks | script) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$2" ;;
    esac
}

#!/bin/bash

#
# print_banner <divider> [msg] ...
#
# Description: Prints out a banner like those used in the comments in this
#              file, using the specified divider argument (e.g. '#' or '=') to
#              build the dividers of the banner. All arguments following will
#              be printed on individual lines prefixed with the divider.
#
print_banner() {
    DIVIDER="$1"
    shift

    printf "%0.s$DIVIDER" {1..80}
    for msg in "$@"; do
        printf '\n%s %s' "$DIVIDER" "$msg"
    done
    printf "\n"
    printf "%0.s$DIVIDER" {1..80}
    printf "\n"
}

is_dry_run() {
    if [ "$DRY_RUN" = "yes" ]; then
        return 0 # true
    else
        return 1 # false
    fi
}

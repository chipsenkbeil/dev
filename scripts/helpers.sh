#!/bin/bash

###############################################################################
# PRINT HELPERS
#
# Description: Helpers for printing operations.
###############################################################################

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

truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    "" | 0 | no | false | off) return 1 ;;
    *) return 0 ;;
    esac
}

verbose_printf() {
    truthy "${VERBOSE:-}" || return 0

    # shellcheck disable=SC2059  # callers pass printf format strings with \n escapes to interpret
    printf "$@"
}

is_dry_run() {
    if [ "$DRY_RUN" = "yes" ]; then
        return 0 # true
    else
        return 1 # false
    fi
}

log() {
    if [ -n "$LOG_FILE" ] && [ "$NO_LOG" != "yes" ]; then
        echo "$@" >>"$LOG_FILE"
    fi
}

exec_and_log() {
    CMD="$1"
    shift

    # If verbose, print out what we would be executing
    verbose_printf "    - \"$CMD\"\n"

    # If performing a dry run, don't execute the command and return positive
    if is_dry_run; then
        return 0
    fi

    if [ -n "$LOG_FILE" ] && [ "$NO_LOG" != "yes" ]; then
        eval "$CMD" >>"$LOG_FILE" 2>&1
    else
        eval "$CMD"
    fi
}

###############################################################################
# OPERATING SYSTEM HELPERS
#
# Description: Helpers for operating system related tasks.
#
# Note:        Using external program instead of OSTYPE because the OSTYPE
#              environment variable is not set in a cron job by default
###############################################################################

#
# get_os
#
# Description: Prints out the current operating system.
#              (e.g. 'Linux' or 'Darwin')
#
get_os() {
    # NOTE: Using external program instead of OSTYPE because the OSTYPE
    #       environment variable is not set in a cron job by default
    local L_OS
    L_OS="$(uname)"

    printf '%s\n' "$L_OS"
}

#
# is_os <input>
#
# Description: Checks if the current operating system matches the provided
#              input. (e.g. 'Linux' on a Linux box, 'Darwin' on a Mac box)
#
# Note:        Also supports a custom of shorthands, namely 'Mac' for Mac
#              boxes, 'BSD' for FreeBSD boxes, and 'Windows' for Windows
#              boxes.
#
is_os() {
    local L_INPUT="$1"
    local L_OS
    L_OS="$(get_os)"

    case "$L_OS" in
    'Darwin') [ "$L_INPUT" = "$L_OS" ] || [ "$L_INPUT" = "Mac" ] ;;
    'Linux') [ "$L_INPUT" = "$L_OS" ] ;;
    'FreeBSD') [ "$L_INPUT" = "$L_OS" ] || [ "$L_INPUT" = "BSD" ] ;;
    'WindowsNT') [ "$L_INPUT" = "$L_OS" ] || [ "$L_INPUT" = "Windows" ] ;;
    *) [ "$L_INPUT" = "$L_OS" ] ;;
    esac
}

#
# has_prog <prog>
#
# Description: Checks if the current program exists and is available in
#              the current path.
#
has_prog() {
    local L_PROG="$1"
    [ -n "$L_PROG" ] && [ -x "$(command -v "$L_PROG")" ]
}

###############################################################################
# ARGUMENT SHAPING HELPERS
#
# Description: Helpers for constructing arguments for other functions.
###############################################################################

#
# check_progs_and_select <prog1> <text1> <prog2> <text2> ...
#
# Description: Checks if program 1 exists, if it does then the text
#              argument following is printed. Otherwise, checks the next
#              program is checked, and so on until arguments are exhausted.
#
#              If * is provided as a program, it is treated as a program
#              that exists and its paired text is printed.
#
#              If no program exists and * is not provided, nothing is printed.
#
# Note:        Assumes that an even number of arguments is provided!
#
check_progs_and_select() {
    local L_PROG=""
    local L_TEXT=""
    local L_SELECT=""

    for arg in "$@"; do
        # Build up our program/text tuple without relying on anything
        # complicated to do so
        if [ -z "$L_PROG" ]; then
            L_PROG="$arg"
        elif [ -z "$L_TEXT" ]; then
            L_TEXT="$arg"
        fi

        # If we have a full set of inputs collected, evaluate if
        # found a match
        if [ -n "$L_PROG" ] && [ -n "$L_TEXT" ]; then
            # TODO: Figure out way to logically combine both conditions
            if has_prog "$L_PROG"; then
                L_SELECT="$L_TEXT"
                break
            elif [ "$L_PROG" = "*" ]; then
                L_SELECT="$L_TEXT"
                break
            fi

            # No match, so reset arguments for next round of collection
            L_PROG=""
            L_TEXT=""
        fi
    done

    if [ -n "$L_SELECT" ]; then
        printf '%s\n' "$L_SELECT"
    fi
}

###############################################################################
# SINGLE PROG/EXPRESSION CHECK AND INSTALL HELPERS
#
# Description: Helpers geared towards checking for the existence of a single
#              program or evaluation of a single expression. If the program
#              is missing or expression is true, the sequence of arguments
#              will be evaluated.
#
#              The difference between install and chain_install is that install
#              will run each argument as a separate command, meaning all will
#              be evaluated regardless of success. chain_install will build a
#              single command with && separating each step, meaning that any
#              failure will halt the remaining sequence.
#
# Note:        All of these commands rely on the variable LOG_FILE being set,
#              which is used to output progress and results to the specified
#              file.
#
#              Will not run the install commands if DRY_RUN is "yes", and counts each as a success.
###############################################################################

#
# check_prog_and_install <prog> [cmd] ...
#
# Description: Checks if the current program is installed and on path. If not,
#              will evaluate all remaining arguments as individual commands.
#
# Note:        Will print check and installation progress to stdout.
#
check_prog_and_install() {
    PROG="$1"
    shift
    CODE=0

    printf 'Checking if %s installed... ' "$PROG"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    if has_prog "$PROG"; then
        printf "YES!\n"
    else
        printf "NO! INSTALLING... "
        verbose_printf "\n>> Commands:\n"

        install_and_log "$PROG" "$@"
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
            fi
        fi
    fi
    return "$CODE"
}

#
# check_prog_and_chain_install <prog> [cmd] ...
#
# Description: Checks if the current program is installed and on path. If not,
#              will evaluate all remaining arguments as chain of commands.
#
# Note:        Will print check and installation progress to stdout.
#
check_prog_and_chain_install() {
    PROG="$1"
    shift
    CODE=0

    printf 'Checking if %s installed... ' "$PROG"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    if has_prog "$PROG"; then
        printf "YES!\n"
    else
        printf "NO! INSTALLING... "
        verbose_printf "\n>> Commands:\n"

        chain_install_and_log "$PROG" "$@"
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
            fi
        fi
    fi
    return "$CODE"
}

#
# check_expr_and_install <label> <expr> [cmd] ...
#
# Description: Checks if the expression is non-empty. If not, will evaluate
#              all remaining arguments as individual commands.
#
# Note:        Does not actually evaluate the expression! The assumption is
#              that the expression was evaluated and its results were fed in
#              as an argument.
#
#              Will print check (using label) and installation
#              progress to stdout.
#
check_expr_and_install() {
    LABEL="$1"
    shift
    EXPRESSION="$1"
    shift
    CODE=0

    printf 'Checking if %s installed... ' "$LABEL"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    if [ ! -z "$EXPRESSION" ]; then
        printf "YES!\n"
    else
        printf "NO! INSTALLING... "
        verbose_printf "\n>> Commands:\n"

        install_and_log "$LABEL" "$@"
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
            fi
        fi
    fi
    return "$CODE"
}

#
# check_expr_and_chain_install <label> <expr> [cmd] ...
#
# Description: Checks if the expression is non-empty. If not, will evaluate
#              all remaining arguments as chain of commands.
#
# Note:        Does not actually evaluate the expression! The assumption is
#              that the expression was evaluated and its results were fed in
#              as an argument.
#
#              Will print check (using label) and installation
#              progress to stdout.
#
check_expr_and_chain_install() {
    LABEL="$1"
    shift
    EXPRESSION="$1"
    shift
    CODE=0

    printf 'Checking if %s installed... ' "$LABEL"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    if [ -n "$EXPRESSION" ]; then
        printf "YES!\n"
    else
        printf "NO! INSTALLING... "

        verbose_printf "\n>> Commands:\n"

        chain_install_and_log "$LABEL" "$@"
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
            fi
        fi
    fi
    return "$CODE"
}

#
# chain_install_and_log <label> [cmd] ...
#
# Description: Evaluates all remaining arguments after first as chain
#              of commands. Return code is the result of the chain,
#              meaning 0 indicates full success of chain.
#
# Note:        Will print label and evaluation to LOG_FILE.
#              Will not run the commands if DRY_RUN is "yes", and counts each as a success.
#
chain_install_and_log() {
    LABEL=$1
    shift

    INSTALL_CMD=
    for cmd in "$@"; do
        if [ -z "$INSTALL_CMD" ]; then
            INSTALL_CMD="$cmd"
        else
            INSTALL_CMD="$INSTALL_CMD && $cmd"
        fi
    done

    # Run our install command and pass along its exit code
    install_and_log "$LABEL" "$INSTALL_CMD"
    return
}

#
# install_and_log <label> [cmd] ...
#
# Description: Evaluates all remaining arguments after first as
#              series of separate commands. Return code is the
#              summation of all commands, meaning 0 indicates
#              full success of all individual commands.
#
# Note:        Will print label and evaluation to LOG_FILE.
#              Will not run the commands if DRY_RUN is "yes", and counts each as a success.
#
install_and_log() {
    LABEL="$1"
    shift
    CODE=0

    log "[[[ $LABEL ]]]"
    for cmd in "$@"; do
        # Evaluate command if it is non-empty (skip empty strings)
        if [ -n "$cmd" ]; then
            exec_and_log "$cmd"
            CODE="$((CODE + $?))"
        fi
    done
    log ""

    # Return sum of exit codes; if result is 0, all commands ran successfully
    return "$CODE"
}

#
# is_brew_formula_installed <formula>
#
# Description: Checks if the current formula is installed.
#
# Note:        Will print check and return 0 if installed, or 1 if not.
#
is_brew_formula_installed() {
    FORMULA="$1"
    shift

    if $BREW list "$FORMULA" &>/dev/null; then
        return 0 # true
    else
        return 1 # false
    fi
}

#
# is_app_installed <name>
#
# Description: Checks if an application <name> exists in /Applications or
#              ~/Applications.
is_app_installed() {
    APP="$1.app"
    shift
    [[ -d "/Applications/$APP" || -d "$HOME/Applications/$APP" ]]
}

# Function to check if a program is in PATH
#
# is_in_path <cmd>
#
# Description: Checks if a program CMD is in our path.
#
# Note: Uses command to check.
is_in_path() {
    command -v "$1" >/dev/null 2>&1
}

#
# cask_app_name <formula>
#
# Description: Looks up the .app bundle name a cask installs (e.g. the
#              "syncthing-app" cask installs "Syncthing.app"). Prints the
#              bundle name (with .app suffix) or nothing if not a known cask.
#
cask_app_name() {
    FORMULA="$1"
    $BREW info --json=v2 --cask "$FORMULA" 2>/dev/null |
        $SYS_JQ -r '.casks[0].artifacts[]? | select(.app) | .app[0]' 2>/dev/null
}

#
# brew_install <formula> [flags] ...
#
# Description: Checks if the current formula is installed, and uses homebrew
#              to install it if not the case. Flags can be provided as
#              additional arguments, which will be fed to the install cmd.
#
# Note:        Will print check and installation progress to stdout.
#              Sets BREW_INSTALL_DID_INSTALL=1 iff a fresh install was
#              actually performed (so callers can run post-install steps).
#
brew_install() {
    FORMULA="$1"
    shift
    CODE=0
    BREW_INSTALL_DID_INSTALL=0

    # Detect --cask in remaining flags so we can also recognize manually
    # installed apps whose bundle name differs from the cask name.
    IS_CASK=0
    for arg in "$@"; do
        if [ "$arg" = "--cask" ]; then
            IS_CASK=1
            break
        fi
    done

    printf 'Checking if homebrew formula %s installed... ' "$FORMULA"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    CASK_APP=""
    if [ "$IS_CASK" -eq 1 ]; then
        CASK_APP="$(cask_app_name "$FORMULA")"
    fi

    if is_brew_formula_installed "$FORMULA"; then
        printf "YES!\n"
    elif is_in_path "$FORMULA"; then
        printf "INSTALLED MANUALLY IN PATH. SKIPPING!\n"
    elif is_app_installed "$FORMULA"; then
        printf "INSTALLED MANUALLY AS APP. SKIPPING!\n"
    elif [ -n "$CASK_APP" ] && is_app_installed "${CASK_APP%.app}"; then
        printf 'INSTALLED MANUALLY AS APP (%s). SKIPPING!\n' "$CASK_APP"
    else
        printf "NO! INSTALLING... "
        verbose_printf "\n>> Commands:\n"

        if ! is_dry_run; then
            install_and_log "Homebrew Formula $FORMULA" "$BREW install $FORMULA $*"
        fi
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
                BREW_INSTALL_DID_INSTALL=1
            fi
        fi
    fi

    return "$CODE"
}

#
# brew_cask_install <formula> [flags] ...
#
# Description: Checks if the current formula is installed, and uses homebrew
#              to install it if not the case. Flags can be provided as
#              additional arguments, which will be fed to the install cmd.
#
#              This is the cask variant of brew_install. After a successful
#              install, it auto-detects whether the app is quarantined and
#              fails Gatekeeper assessment, clearing quarantine if needed.
#
# Note:        Will print check and installation progress to stdout.
#
brew_cask_install() {
    FORMULA="$1"
    shift
    brew_install "$FORMULA" "--cask" "$@"
    CODE="$?"

    # Only run post-install steps when we actually installed in this run.
    # If brew_install short-circuited (already installed, manual install,
    # etc.) we should not be tampering with the app bundle.
    if [ "$CODE" -eq "0" ] && [ "$BREW_INSTALL_DID_INSTALL" -eq "1" ] && ! is_dry_run; then
        APP_NAME="$(cask_app_name "$FORMULA")"

        if [ -n "$APP_NAME" ] && [ -d "/Applications/$APP_NAME" ]; then
            if $SYS_XATTR -p com.apple.quarantine "/Applications/$APP_NAME" >/dev/null 2>&1; then
                if ! $SYS_SPCTL --assess --type execute "/Applications/$APP_NAME" >/dev/null 2>&1; then
                    clear_quarantine "${APP_NAME%.app}"
                fi
            fi
        fi
    fi

    return "$CODE"
}

#
# clear_quarantine <app name>
#
# Description: Clears the quarantine extended attributes from an application
#              bundle in /Applications. This is needed for unsigned apps that
#              macOS will refuse to open due to Gatekeeper.
#
# Note:        Uses -cr (clear, recursive) to handle all files in the bundle.
#
clear_quarantine() {
    APP_NAME="$1"
    shift
    APP_PATH="/Applications/$APP_NAME.app"

    printf 'Clearing quarantine for %s... ' "$APP_NAME"

    if [ ! -d "$APP_PATH" ]; then
        printf "NOT FOUND! SKIPPING.\n"
        return 0
    fi

    exec_and_log "$SYS_XATTR -cr $APP_PATH"
    CODE="$?"

    if is_dry_run; then
        printf "SKIPPING!\n"
    elif [ "$CODE" -gt "0" ]; then
        printf "FAILED!\n"
    else
        printf "DONE!\n"
    fi

    return "$CODE"
}

#
# brew_print_install_browserpass_for_browser <browser>
#
# Description: Installs the host config for the specified browser.
#
# Note:        Prints the command to install the host config.
#
print_brew_install_browserpass_for_browser() {
    BROWSER="$1"
    shift
    printf '%s\n' "PREFIX=\"\$($BREW --prefix browserpass)\" \
        make hosts-$BROWSER-user \
        -f \$($BREW --prefix browserpass)/lib/browserpass/Makefile"
}

#
# ext_to_uti <file ext>
#
# Description: Returns the UTI for a given file extension.
#
# Note:        Prints the UTI out via printf.
#
ext_to_uti() {
    FILE_EXT="$1"
    shift

    # Make a temporary file so we can get the content type
    FILENAME="$($SYS_MKTEMP -u).$FILE_EXT"
    eval "$SYS_TOUCH $FILENAME"

    # Print out the extension's content type
    # shellcheck disable=SC2016  # single quotes are intentional: '{print $2}' is an awk
    # field reference, not a shell expansion
    printf '%s' "$($SYS_MDLS -name kMDItemContentType "$FILENAME" | $SYS_AWK -F '\"' '{print $2}')"

    # Remove the created file
    eval "$SYS_RM $FILENAME"
}

#
# app_name_to_bundle_id <file ext>
#
# Description: Returns the bundle id for an app.
#
# Note:        Prints the bundle id out via printf.
#
app_name_to_bundle_id() {
    APP_NAME="$1"
    shift
    printf '%s' "$($SYS_OSASCRIPT -e "id of app \"$APP_NAME\"")"
}

#
# duti_set_app <bundle id> <uti> [role]
#
# Description: Leverages duti to set a default program for some UTI.
#
# Note:        Will print check and installation progress to stdout.
#
duti_set_default_app() {
    BUNDLE_ID="$1"
    shift
    UTI="$1"
    shift
    ROLE="$1"
    shift
    CODE=0

    # Fail if we are missing UTI
    if [ -z "$UTI" ]; then
        printf 'Skipping setting %s as default, no UTI provided!\n' "$BUNDLE_ID"
        return "1"
    fi

    if [ -z "$ROLE" ]; then
        ROLE="all"
    fi

    printf 'Checking if %s for %s is %s... ' "$BUNDLE_ID" "$UTI" "$ROLE"

    # If printing verbose, we need to make room for verbose output on
    # later lines, so we're moving down
    verbose_printf "\n>> Result: "

    if [ "$($DUTI -d "$UTI" 2>/dev/null)" = "$BUNDLE_ID" ]; then
        printf "YES!\n"
    else
        printf "NO! SETTING... "
        verbose_printf "\n>> Commands:\n"

        if ! is_dry_run; then
            install_and_log "$UTI default app" "$DUTI -s $BUNDLE_ID $UTI $ROLE"
        fi
        CODE="$?"

        verbose_printf ">> Status: "

        if is_dry_run; then
            printf "SKIPPING!\n"
        else
            if [ "$CODE" -gt "0" ]; then
                printf "FAILED!\n"
            else
                printf "DONE!\n"
            fi
        fi
    fi

    return "$CODE"
}

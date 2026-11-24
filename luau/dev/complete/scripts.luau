---@class dev.complete.scripts
local M = {}

---The shells a completion script exists for.
M.SHELLS = { "bash", "zsh", "fish", "powershell" }

local BASH = [=[
# Completion for dev. Load it with: source <(dev completion bash)
_dev_complete() {
    local line value cur prefix w i cword mode=plain joined=0
    local -a words args values
    COMPREPLY=()
    if declare -F _get_comp_words_by_ref >/dev/null; then
        _get_comp_words_by_ref -n =: words cword
    else
        for w in "${COMP_WORDS[@]:0:COMP_CWORD+1}"; do
            if (( ${#words[@]} )) && { [[ $w == [=:] ]] || (( joined )); }; then
                words[${#words[@]}-1]+=$w
                if [[ $w == [=:] ]]; then joined=1; else joined=0; fi
            else
                words+=("$w")
                joined=0
            fi
        done
        cword=$(( ${#words[@]} - 1 ))
    fi
    args=("${words[@]:1:cword}")
    (( ${#args[@]} )) || args=("")
    for (( i = 0; i < ${#args[@]} - 1; i++ )); do
        if [[ ${args[i]} == -C && ${args[i+1]} == "~/"* ]]; then
            args[i+1]=$HOME${args[i+1]:1}
        fi
    done
    cur=${args[${#args[@]}-1]}
    prefix=${cur%"${cur##*[=:]}"}
    while IFS= read -r line; do
        value=${line%%$'\t'*}
        values+=("$value")
        if [[ $line != *$'\t'* && -e ${value/#\~/$HOME} ]]; then
            mode=file
        fi
    done < <(command dev __complete -- "${args[@]}" 2>/dev/null)
    for value in "${values[@]}"; do
        value=${value#"$prefix"}
        if [[ $mode == file ]]; then
            COMPREPLY+=("$value")
        else
            COMPREPLY+=("$(printf '%q' "$value")")
        fi
    done
    if [[ $mode == file ]]; then
        compopt -o filenames 2>/dev/null
    fi
}
complete -F _dev_complete dev
]=]

local ZSH = [=[
#compdef dev
# Completion for dev. Load it with: dev completion zsh > "${fpath[1]}/_dev"
_dev() {
    local -a candidates
    local line value desc
    for line in "${(@f)$(command dev __complete -- "${(@)words[2,CURRENT]}" 2>/dev/null)}"; do
        [[ -n $line ]] || continue
        value=${${(ps:\t:)line}[1]}
        desc=${${(ps:\t:)line}[2]}
        candidates+=("${value//:/\\:}:${desc}")
    done
    if (( $#candidates )); then
        _describe -t values 'dev' candidates
    fi
}
_dev "$@"
]=]

local FISH = [=[
# Completion for dev. Load it with: dev completion fish | source
function __dev_complete
    set -l words (commandline -opc) (commandline -ct)
    command dev __complete -- $words[2..-1] 2>/dev/null
end
complete -c dev -f -a '(__dev_complete)'
]=]

local POWERSHELL = [=[
# Completion for dev. Load it with: dev completion powershell | Out-String | Invoke-Expression
Register-ArgumentCompleter -Native -CommandName dev -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $before = @($commandAst.CommandElements | Select-Object -Skip 1 |
        Where-Object { $_.Extent.EndOffset -le $cursorPosition })
    if ($wordToComplete -ne '') { $before = @($before | Select-Object -SkipLast 1) }
    $words = @($before | ForEach-Object { $_.ToString() })
    dev __complete "--cur=$wordToComplete" -- @words 2>$null | ForEach-Object {
        $value, $desc = $_ -split "`t", 2
        if (-not $desc) { $desc = $value }
        $text = if ($value -match '\s') { "'" + $value.Replace("'", "''") + "'" } else { $value }
        [System.Management.Automation.CompletionResult]::new($text, $value, 'ParameterValue', $desc)
    }
}
]=]

local SCRIPTS = { bash = BASH, zsh = ZSH, fish = FISH, powershell = POWERSHELL }

---Return the completion script of a shell.
---@param shell string one of `SHELLS`
---@return string? script nil for an unknown shell
function M.for_shell(shell)
    return SCRIPTS[shell]
end

return M

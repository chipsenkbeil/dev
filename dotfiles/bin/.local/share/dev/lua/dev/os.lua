local ffi = require("ffi")

ffi.cdef([[
int isatty(int fd);
unsigned int getuid(void);
int execvp(const char *file, char *const argv[]);
char *strerror(int errnum);
]])

local WAIT_SIGNAL_MASK = 0x7f
local WAIT_EXIT_SHIFT = 256

---@class dev.os
---@field SIGNAL_EXIT_BASE integer exit status of a process killed by signal n, which is this plus n
local M = {
    SIGNAL_EXIT_BASE = 128,
}

---Quote `arg` as one shell word.
---@param arg string word to quote, with no NUL byte
---@return string word the word in single quotes
function M.quote(arg)
    if type(arg) ~= "string" then
        error("quote expects a string, got " .. type(arg), 2)
    end
    if arg:find("\0", 1, true) then
        error("quote cannot take an argument with a NUL byte", 2)
    end
    return "'" .. arg:gsub("'", [['\'']]) .. "'"
end

---Join `argv` into one shell command with every word quoted.
---@param argv string[] command and its arguments, with at least one word
---@return string command the quoted command line
function M.command(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("command expects a non-empty argv list", 2)
    end
    local words = {}
    for i, arg in ipairs(argv) do
        words[i] = M.quote(arg)
    end
    return table.concat(words, " ")
end

---@class dev.os.Opts
---@field env table<string,string>? variables set for the command, over `os.defaults.env`
---@field unset string[]? variables removed from the command's environment, besides `os.defaults.unset`
---@field cwd string? directory to run in
---@field stdin "null"? read from /dev/null
---@field stdout string? "null", or a file path to append to, resolved against the caller's directory, not `cwd`
---@field stderr string? "null", a file path to append to (resolved like `stdout`), or "stdout" to merge into standard output

---@class dev.os.Defaults
---@field env table<string,string> variables set for every command
---@field unset string[] variables removed from every command's environment
---@field show boolean write each command to standard error before it runs
M.defaults = { env = {}, unset = {}, show = false }

---Name the operating system.
---@return "Darwin"|"Linux"|"Windows" name the system name
function M.name()
    local names = { OSX = "Darwin", Linux = "Linux", Windows = "Windows" }
    return names[ffi.os] or ffi.os
end

local ENV_NAME = "^[A-Za-z_][A-Za-z0-9_]*$"
local CHECK_LEVEL = 3

local function check(opts)
    local merged = {}
    for name, value in pairs(M.defaults.env) do
        merged[name] = value
    end
    for _, name in ipairs(M.defaults.unset) do
        merged[name] = nil
    end
    for name, value in pairs(opts.env or {}) do
        merged[name] = value
    end
    for _, name in ipairs(opts.unset or {}) do
        merged[name] = nil
    end
    local names = {}
    for name in pairs(merged) do
        if type(name) ~= "string" or not name:match(ENV_NAME) then
            error("env name " .. tostring(name) .. " is not a valid variable name", CHECK_LEVEL)
        end
        names[#names + 1] = name
    end
    table.sort(names)
    local words = {}
    local unset = {}
    for _, list in ipairs({ M.defaults.unset, opts.unset or {} }) do
        for _, name in ipairs(list) do
            if not name:match(ENV_NAME) then
                error("env name " .. tostring(name) .. " is not a valid variable name", CHECK_LEVEL)
            end
            unset[#unset + 1] = name
        end
    end
    table.sort(unset)
    for _, name in ipairs(unset) do
        words[#words + 1] = "-u"
        words[#words + 1] = name
    end
    if #names > 0 or #words > 0 then
        words[#words + 1] = "--"
    end
    for _, name in ipairs(names) do
        words[#words + 1] = name .. "=" .. merged[name]
    end
    if opts.stdin ~= nil and opts.stdin ~= "null" then
        error('stdin must be "null" or unset', CHECK_LEVEL)
    end
    if opts.stdout == "stdout" or opts.stdout == "stderr" or opts.stderr == "stderr" then
        error("only stderr can merge, and only into stdout", CHECK_LEVEL)
    end
    return words
end

local function redirect(fd, target)
    if target == nil then
        return ""
    end
    if target == "null" then
        return " " .. fd .. ">/dev/null"
    end
    if target == "stdout" then
        return " 2>&1"
    end
    return " " .. fd .. ">>" .. M.quote(target)
end

local function redirects(opts)
    return (opts.stdin and " </dev/null" or "")
        .. redirect(1, opts.stdout)
        .. redirect(2, opts.stderr)
end

local function directory(cwd)
    if cwd:sub(1, 1) == "/" then
        return cwd
    end
    return "./" .. cwd
end

local function announce(argv)
    if M.defaults.show then
        local stderr = io.stderr
        stderr:write("+ ", M.command(argv), "\n")
    end
end

local function past_env(argv, words)
    if #words == 0 or not argv[1]:find("=", 1, true) then
        return argv
    end
    return { "sh", "-c", 'exec "$@"', "sh", unpack(argv) }
end

local function shell_line(argv, opts, words)
    local command = M.command(past_env(argv, words))
    if #words > 0 then
        local quoted = {}
        for i, word in ipairs(words) do
            quoted[i] = M.quote(word)
        end
        command = "env " .. table.concat(quoted, " ") .. " " .. command
    end
    if opts.cwd then
        command = "( cd -- " .. M.quote(directory(opts.cwd)) .. " && " .. command .. " )"
    end
    return command .. redirects(opts)
end

---Describe the current errno.
---@return string message the system's text for the last failed call
function M.strerror()
    return ffi.string(ffi.C.strerror(ffi.errno()))
end

local function flush_output()
    local stdout, stderr = io.stdout, io.stderr
    stdout:flush()
    stderr:flush()
end

local function decode(status)
    if status == true then
        return 0
    end
    if type(status) ~= "number" then
        return nil
    end
    local signal = bit.band(status, WAIT_SIGNAL_MASK)
    if status % WAIT_EXIT_SHIFT == 0 then
        return status / WAIT_EXIT_SHIFT
    end
    return M.SIGNAL_EXIT_BASE + signal
end

---Run `argv` with the terminal's streams and wait for it.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return integer? code exit status, or the signal exit base plus the signal when killed
function M.run(argv, opts)
    opts = opts or {}
    local command = shell_line(argv, opts, check(opts))
    announce(argv)
    flush_output()
    local ok, kind, code = os.execute(command)
    if type(ok) == "number" then
        return decode(ok)
    end
    if kind == "signal" then
        return M.SIGNAL_EXIT_BASE + code
    end
    return code
end

---Run `argv` and collect its standard output.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return string output everything the command wrote to standard output
---@return integer? code exit status of the command
function M.capture(argv, opts)
    opts = opts or {}
    local command = shell_line(argv, opts, check(opts))
    announce(argv)
    flush_output()
    local pipe = assert(io.popen(command .. [[; printf '\n%d' "$?"]], "r"))
    local text = pipe:read("*a")
    pipe:close()
    local split = text:match("^.*()\n")
    if not split then
        error("capture lost the exit status of " .. command)
    end
    return text:sub(1, split - 1), tonumber(text:sub(split + 1))
end

---Find `name` on PATH.
---@param name string command name to look up
---@return string? path absolute path, or nil when `name` is not on PATH
function M.which(name)
    local out, code = M.capture({ "sh", "-c", [[command -v -- "$1"]], "sh", name })
    if code ~= 0 then
        return nil
    end
    local path = out:match("^[^\n]+")
    if path and path:sub(1, 1) == "/" then
        return path
    end
    return nil
end

---Read the real user id.
---@return integer uid user id of the process
function M.getuid()
    return tonumber(ffi.C.getuid())
end

---Check whether `fd` is a terminal.
---@param fd integer file descriptor to check
---@return boolean tty true when `fd` is a terminal
function M.isatty(fd)
    return ffi.C.isatty(fd) == 1
end

---Replace this process with `argv`.
---
---Only returns when the exec fails.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return nil
---@return string message why the exec failed
function M.exec(argv, opts)
    if type(argv) ~= "table" or #argv == 0 then
        error("exec expects a non-empty argv list", 2)
    end
    opts = opts or {}
    local words = check(opts)
    announce(argv)
    local streams = redirects(opts)
    if opts.cwd or streams ~= "" then
        local wrapped = {
            "sh",
            "-c",
            (streams ~= "" and "exec" .. streams .. "; " or "")
                .. (opts.cwd and 'cd -- "$1" && shift && ' or "")
                .. 'exec "$@"',
            "sh",
        }
        if opts.cwd then
            wrapped[#wrapped + 1] = directory(opts.cwd)
        end
        for _, arg in ipairs(argv) do
            wrapped[#wrapped + 1] = arg
        end
        argv = wrapped
    end
    argv = past_env(argv, words)
    if #words > 0 then
        local prefixed = { "env" }
        for _, word in ipairs(words) do
            prefixed[#prefixed + 1] = word
        end
        for _, arg in ipairs(argv) do
            prefixed[#prefixed + 1] = arg
        end
        argv = prefixed
    end
    local count = #argv
    local cargs = ffi.new("char *[?]", count + 1)
    local keep = {}
    for i, arg in ipairs(argv) do
        if arg:find("\0", 1, true) then
            error("exec cannot take an argument with a NUL byte", 2)
        end
        local buf = ffi.new("char[?]", #arg + 1)
        ffi.copy(buf, arg, #arg)
        keep[i] = buf
        cargs[i - 1] = buf
    end
    flush_output()
    ffi.C.execvp(argv[1], cargs)
    return nil, M.strerror()
end

return M

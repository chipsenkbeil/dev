local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")

local MAX_TMP_BASE_CHARS = 40

---The shell that removes the scratch directory and kills the suites when dev dies.
local GUARD = [=[
set -m
watched=$1
scratch=$2
(
    trap '' INT TERM HUP
    while [ -d "$scratch" ] && kill -0 "$watched" 2>/dev/null; do sleep 0.2; done
    if [ -d "$scratch" ]; then
        for sig in TERM KILL; do
            for pidfile in "$scratch"/*.pid; do
                [ -f "$pidfile" ] && [ ! -e "${pidfile%.pid}.status" ] &&
                    kill -"$sig" -- "-$(cat "$pidfile")" 2>/dev/null
            done
            [ "$sig" = TERM ] && sleep 1
        done
        sleep 0.5
        rm -rf -- "$scratch" || { sleep 1; rm -rf -- "$scratch"; }
    fi
) </dev/null >/dev/null 2>&1 &
]=]

---The shell that starts one suite in its own process group and prints the group's pid.
local LAUNCH = [[
set -m
trap '' INT
out=$1
status=$2
dir=$3
pidfile=$4
stopfile=$5
shift 5
(
    trap - INT
    ( cd -- "$dir" && "$@" ) >"$out" 2>&1 </dev/null
    echo "$?" >"$status.tmp"
    mv "$status.tmp" "$status"
) >/dev/null 2>&1 </dev/null &
{ echo "$!" >"$pidfile"; } 2>/dev/null
if [ -e "$stopfile" ] || [ ! -d "${stopfile%/*}" ]; then
    kill -TERM -- "-$!" 2>/dev/null
fi
echo "$!"
]]

---The shell that ends every suite that is still running.
local STOP = [=[
for pidfile in "$1"/*.pid; do
    [ -f "$pidfile" ] && [ ! -e "${pidfile%.pid}.status" ] &&
        kill -TERM -- "-$(cat "$pidfile")" 2>/dev/null
done
exit 0
]=]

---@class devrepo.supervise.Supervisor
---@field root string the project root the suites run in
---@field scratch string the directory that holds the suites' output and status files
---@field stop_marker string the file whose presence stops new suites from starting
local Supervisor = {}
Supervisor.__index = Supervisor

---@class devrepo.supervise
local M = {}

local function scratch_dir()
    local base = (dev_os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    if #base > MAX_TMP_BASE_CHARS or base:sub(1, 1) ~= "/" then
        base = "/tmp"
    end
    local out, code = dev_os.capture({ "mktemp", "-d", base .. "/dt.XXXXXX" })
    assert(code == 0, "The test run cannot make a scratch directory under " .. base .. ".")
    return (out:gsub("\n$", ""))
end

---Make the scratch directory and start the guard that cleans it up when dev dies.
---@param root string the project root the suites run in
---@return devrepo.supervise.Supervisor supervisor the supervisor
function M.new(root)
    local scratch = scratch_dir()
    local self = setmetatable(
        { root = root, scratch = scratch, stop_marker = scratch .. "/stop" },
        Supervisor
    )
    dev_os.run({ "sh", "-c", GUARD, "sh", tostring(dev_os.getpid()), scratch })
    return self
end

---Start a suite in its own process group.
---@param index integer the suite's place in the run, which names its files
---@param suite table the suite, whose `argv` runs and which gets its file names and pid
function Supervisor:start(index, suite)
    local base = self.scratch .. "/" .. index
    suite.out, suite.status, suite.tmp = base .. ".out", base .. ".status", base .. ".t"
    assert(fs.mkdir(suite.tmp))
    suite.pidfile = base .. ".pid"
    local argv = {
        "sh",
        "-c",
        LAUNCH,
        "sh",
        suite.out,
        suite.status,
        self.root,
        suite.pidfile,
        self.stop_marker,
    }
    for _, word in ipairs(suite.argv) do
        argv[#argv + 1] = word
    end
    local path = fs.dirname(runtime.exe) .. ":" .. (dev_os.getenv("PATH") or "")
    local pid = dev_os.capture(argv, {
        env = { TMPDIR = suite.tmp, DEV_FROM = "checkout", DEV_BIN = runtime.exe, PATH = path },
    })
    suite.pid = pid:match("%d+")
    suite.started = true
end

local function status_of(suite)
    local text = fs.read(suite.status)
    return text and (tonumber(text:match("%d+")) or 1)
end

---Read a suite's exit code once it has finished.
---@param suite table a started suite
---@param check_alive boolean whether to look for a suite whose process died without a status
---@return integer? code the exit code, nil while the suite runs
function Supervisor:finished(suite, check_alive)
    local code = status_of(suite)
    if code or not check_alive or not suite.pid then
        return code
    end
    local alive = dev_os.run({ "kill", "-0", suite.pid }, { stderr = "null" }) == 0
    if alive then
        return nil
    end
    return status_of(suite) or 1
end

---Stop every running suite and keep new ones from starting.
function Supervisor:stop_all()
    fs.write(self.stop_marker, "")
    dev_os.run({ "sh", "-c", STOP, "sh", self.scratch }, { stderr = "null" })
end

---Remove the scratch directory.
function Supervisor:cleanup()
    dev_os.run({ "rm", "-rf", "--", self.scratch })
end

return M

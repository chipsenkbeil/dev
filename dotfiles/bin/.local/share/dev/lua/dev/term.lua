local ffi = require("ffi")
local devos = require("dev.os")

local TCSANOW = 0
local O_RDWR = 2
local DEFAULT_ROWS, DEFAULT_COLS = 24, 80
local ESC_TIMEOUT_TENTHS = 1
local EINTR = 4
local CSI_FINAL_MIN, CSI_FINAL_MAX = 0x40, 0x7e

local ICANON, ECHO, ISIG, VMIN, VTIME, O_CLOEXEC
if ffi.os == "OSX" then
    ffi.cdef([[
typedef unsigned long tcflag_t;
typedef unsigned char cc_t;
typedef unsigned long speed_t;
struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t c_cc[20];
    speed_t c_ispeed;
    speed_t c_ospeed;
};
]])
    ICANON, ECHO, ISIG, VMIN, VTIME = 0x100, 0x8, 0x80, 16, 17
    O_CLOEXEC = 0x1000000
elseif ffi.os == "Linux" then
    ffi.cdef([[
typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
typedef unsigned int speed_t;
struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t c_line;
    cc_t c_cc[32];
    speed_t c_ispeed;
    speed_t c_ospeed;
};
]])
    ICANON, ECHO, ISIG, VMIN, VTIME = 0x2, 0x8, 0x1, 6, 5
    O_CLOEXEC = 0x80000
else
    error("dev.term has no termios layout for " .. ffi.os)
end

ffi.cdef([[
int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
long read(int fd, void *buf, unsigned long count);
int open(const char *path, int flags, ...);
int close(int fd);
]])

---@class dev.term.Key
---@field UP string arrow up, ctrl-p or k
---@field DOWN string arrow down, ctrl-n or j
---@field ENTER string return or newline
---@field ESC string a lone escape byte
---@field CTRL_C string ctrl-c, delivered as a key in raw mode
---@field SPACE string the space bar
---@field EOF string the terminal closed or failed

---@class dev.term
---@field TTY_PATH string path of the controlling terminal
---@field Key dev.term.Key names read_key and decode return for the keys they know
local M = {
    TTY_PATH = "/dev/tty",
    Key = {
        UP = "up",
        DOWN = "down",
        ENTER = "enter",
        ESC = "esc",
        CTRL_C = "ctrl-c",
        SPACE = "space",
        EOF = "eof",
    },
}

local Key = M.Key

local function get_attr(fd)
    local attr = ffi.new("struct termios[1]")
    if ffi.C.tcgetattr(fd, attr) ~= 0 then
        error("tcgetattr failed on fd " .. fd .. ": " .. devos.strerror(), 3)
    end
    return attr
end

local function set_attr(fd, attr)
    if ffi.C.tcsetattr(fd, TCSANOW, attr) ~= 0 then
        error("tcsetattr failed on fd " .. fd .. ": " .. devos.strerror(), 3)
    end
end

---@class dev.term.Limits
---@field vmin integer bytes a read waits for before it returns
---@field vtime integer tenths of a second a read waits before it gives up

local function with_read_limits(fd, limits, fn)
    local saved = get_attr(fd)
    local limited = ffi.new("struct termios[1]")
    ffi.copy(limited, saved, ffi.sizeof("struct termios"))
    limited[0].c_cc[VMIN] = limits.vmin
    limited[0].c_cc[VTIME] = limits.vtime
    set_attr(fd, limited)
    local ok, result = pcall(fn)
    set_attr(fd, saved)
    if not ok then
        error(result, 0)
    end
    return result
end

---Put `fd` in raw mode, where each key arrives alone, unechoed and with no signals.
---
---Calling the returned function more than once restores only the first time.
---@param fd integer terminal file descriptor
---@return fun() restore puts the terminal back as it was
function M.raw(fd)
    if not devos.isatty(fd) then
        error("fd " .. fd .. " is not a terminal", 2)
    end
    local saved = get_attr(fd)
    local raw = ffi.new("struct termios[1]")
    ffi.copy(raw, saved, ffi.sizeof("struct termios"))
    raw[0].c_lflag = bit.band(raw[0].c_lflag, bit.bnot(bit.bor(ICANON, ECHO, ISIG)))
    raw[0].c_cc[VMIN] = 1
    raw[0].c_cc[VTIME] = 0
    set_attr(fd, raw)
    local restored = false
    return function()
        if restored then
            return
        end
        restored = true
        set_attr(fd, saved)
    end
end

---Open the controlling terminal for reading and writing.
---
---The descriptor is not inherited by child processes.
---@return integer? fd descriptor, or nil when there is no controlling terminal
---@return string? message why the open failed, set only when `fd` is nil
function M.open_tty()
    local fd = ffi.C.open(M.TTY_PATH, bit.bor(O_RDWR, O_CLOEXEC))
    if fd < 0 then
        return nil, devos.strerror()
    end
    return fd
end

---Close a descriptor from `open_tty`.
---@param fd integer descriptor to close
function M.close(fd)
    ffi.C.close(fd)
end

---Measure the controlling terminal.
---@return integer rows row count, or 24 when the size is unknown
---@return integer cols column count, or 80 when the size is unknown
function M.size()
    local out, code =
        devos.capture({ "sh", "-c", "{ stty size <" .. M.TTY_PATH .. "; } 2>/dev/null" })
    if code == 0 then
        local rows, cols = out:match("^(%d+)%s+(%d+)")
        rows, cols = tonumber(rows), tonumber(cols)
        if rows and cols and rows > 0 and cols > 0 then
            return rows, cols
        end
    end
    return DEFAULT_ROWS, DEFAULT_COLS
end

local ESCAPE_KEYS = {
    ["[A"] = Key.UP,
    ["OA"] = Key.UP,
    ["[B"] = Key.DOWN,
    ["OB"] = Key.DOWN,
}

local BYTE_KEYS = {
    ["\r"] = Key.ENTER,
    ["\n"] = Key.ENTER,
    ["\3"] = Key.CTRL_C,
    ["\16"] = Key.UP,
    ["\14"] = Key.DOWN,
    [" "] = Key.SPACE,
    ["k"] = Key.UP,
    ["j"] = Key.DOWN,
}

local function is_csi_final(byte)
    return byte >= CSI_FINAL_MIN and byte <= CSI_FINAL_MAX
end

local function escape_length(bytes, start)
    local introducer = bytes:sub(start + 1, start + 1)
    if introducer == "O" then
        return 2
    end
    if introducer ~= "[" then
        return 0
    end
    local pos = start + 2
    while pos <= #bytes do
        if is_csi_final(bytes:byte(pos)) then
            return pos - start
        end
        pos = pos + 1
    end
    return #bytes - start
end

---Turn raw terminal bytes into key names.
---
---An escape sequence it does not know is skipped, and any other printable byte is its own name.
---@param bytes string bytes read from the terminal
---@return string[] keys key names in the order they were pressed
function M.decode(bytes)
    local keys = {}
    local pos = 1
    while pos <= #bytes do
        local char = bytes:sub(pos, pos)
        if char == "\27" then
            local length = escape_length(bytes, pos)
            if length == 0 then
                keys[#keys + 1] = Key.ESC
                pos = pos + 1
            else
                local key = ESCAPE_KEYS[bytes:sub(pos + 1, pos + length)]
                if key then
                    keys[#keys + 1] = key
                end
                pos = pos + length + 1
            end
        else
            local byte = char:byte()
            local key = BYTE_KEYS[char] or (byte >= 0x20 and byte < 0x7f and char) or nil
            if key then
                keys[#keys + 1] = key
            end
            pos = pos + 1
        end
    end
    return keys
end

local function read_byte(fd)
    local buf = ffi.new("char[1]")
    local count
    repeat
        count = tonumber(ffi.C.read(fd, buf, 1))
    until count >= 0 or ffi.errno() ~= EINTR
    if count <= 0 then
        return nil
    end
    return string.char(buf[0] % 256)
end

local function read_escape_tail(fd)
    return with_read_limits(fd, { vmin = 0, vtime = ESC_TIMEOUT_TENTHS }, function()
        local tail = ""
        local introducer = read_byte(fd)
        if not introducer then
            return tail
        end
        tail = introducer
        if introducer ~= "[" and introducer ~= "O" then
            return tail
        end
        repeat
            local byte = read_byte(fd)
            if not byte then
                break
            end
            tail = tail .. byte
        until introducer == "O" or is_csi_final(byte:byte())
        return tail
    end)
end

---Block until `fd` delivers a key the decoder knows.
---@param fd integer terminal file descriptor, already in raw mode
---@return string key key name, or `Key.EOF` when the terminal closed or failed
function M.read_key(fd)
    while true do
        local first = read_byte(fd)
        if not first then
            return Key.EOF
        end
        local bytes = first
        if first == "\27" then
            bytes = first .. read_escape_tail(fd)
        end
        local keys = M.decode(bytes)
        if keys[1] then
            return keys[1]
        end
    end
end

return M

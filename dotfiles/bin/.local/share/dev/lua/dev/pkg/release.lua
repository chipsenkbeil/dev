local dev_os = require("dev.os")
local fs = require("dev.fs")
local lib = require("dev.pkg.lib")
local manifest = require("dev.pkg.manifest")
local note = require("dev.verb").note

local stdout = io.stdout

local NO_PATH = "-"
local SHA256_LENGTH = 64

---@class dev.pkg.release.Pin
---@field name string the tool's name
---@field version string the pinned version
---@field sha256 string the lowercase checksum of the download
---@field url string the download address with `${version}` replaced
---@field path string the binary's path inside the archive, `-` for a bare binary

---The reasons a fetch refuses a pin
---@enum dev.pkg.release.Reason
local Reason = {
    NO_HASHER = "no_hasher",
    HASH_FAILED = "hash_failed",
    MISMATCH = "mismatch",
    NO_FILE = "no_file",
    DOWNLOAD = "download",
    EXTRACT = "extract",
}

---@class dev.pkg.release
---@field Reason table<string, dev.pkg.release.Reason> the reasons `fetch` names
local M = { Reason = Reason }

local ARCHIVES = {
    { suffix = ".tar.gz", flags = "-xzf" },
    { suffix = ".tgz", flags = "-xzf" },
    { suffix = ".tar.xz", flags = "-xJf" },
}
local ZIP_SUFFIX = ".zip"

local function archive_flags(url)
    for _, archive in ipairs(ARCHIVES) do
        if url:sub(-#archive.suffix) == archive.suffix then
            return archive.flags
        end
    end
end

local function is_zip(url)
    return url:sub(-#ZIP_SUFFIX) == ZIP_SUFFIX
end

local function is_archive(url)
    return archive_flags(url) ~= nil or is_zip(url)
end

local function bad_path(path)
    return path:sub(1, 1) == "/"
        or path:sub(1, 1) == "-"
        or path:find("%.%.") ~= nil
        or path:find("[%c%s]") ~= nil
end

local VERSION_WORD = "^[A-Za-z0-9._+][A-Za-z0-9._+%-]*$"
local NAME_WORD = "^[A-Za-z0-9@._+][A-Za-z0-9@._+%-]*$"
local SHA256_WORD = "^%x+$"

local function pin_of(fields, line)
    local name, version, sha256, url, path = unpack(fields, 1, 5)
    if #fields ~= 5 then
        return nil, line .. ": a pin has name, version, sha256, url and path"
    elseif not name:find(NAME_WORD) then
        return nil, line .. ": bad name " .. name
    elseif not version:find(VERSION_WORD) then
        return nil, line .. ": bad version " .. version
    elseif #sha256 ~= SHA256_LENGTH or not sha256:find(SHA256_WORD) then
        return nil, line .. ": the sha256 of " .. name .. " is not 64 hex digits"
    end
    url = url:gsub("%${version}", (version:gsub("%%", "%%%%")))
    if not url:find("^https://[^%s]+$") or url:find("[%c\"'`$\\]") then
        return nil, line .. ": the url of " .. name .. " must be https and a plain word"
    elseif path ~= NO_PATH and bad_path(path) then
        return nil, line .. ": bad archive path " .. path
    elseif is_archive(url) == (path == NO_PATH) then
        return nil,
            line .. ": " .. name .. " needs a path in the archive exactly when its url is one"
    end
    return { name = name, version = version, sha256 = sha256:lower(), url = url, path = path }
end

---Read a pins file.
---
---Columns split like the manifest's: the first row that is not a comment is the header, then
---one row per pin with name, version, sha256, url and the binary's path in the archive.
---@param path string the pins file
---@return table<string, dev.pkg.release.Pin>? pins the pins by name, nil when the file is unusable
---@return string? err what is wrong, naming the file
function M.read(path)
    local text, why = fs.read(path)
    if not text then
        return nil, path .. ": " .. tostring(why)
    end
    local rows = manifest.parse(text)
    local pins = {}
    for i, row in ipairs(rows) do
        local pin, err = pin_of(row.fields, path .. " row " .. i)
        if not pin then
            return nil, err
        elseif pins[pin.name] then
            return nil, path .. ": two pins named " .. pin.name
        end
        pins[pin.name] = pin
    end
    return pins
end

local function bin_dir()
    local dir = os.getenv("DEV_TOOLS_BIN")
    if dir and dir ~= "" then
        return dir
    end
    local home = os.getenv("HOME")
    if home and home ~= "" then
        return fs.join(home, ".local", "bin")
    end
end

local function target_name(row)
    return row.binary ~= NO_PATH and fs.basename(row.binary) or row.package
end

local function checksum_command(file)
    if dev_os.which("shasum") then
        return { "shasum", "-a", "256", file }
    elseif dev_os.which("sha256sum") then
        return { "sha256sum", file }
    end
end

local function sha256_of(file)
    local argv = checksum_command(file)
    if not argv then
        return nil, nil, Reason.NO_HASHER
    end
    local out, code = dev_os.capture(argv, { stdin = "null", stderr = "null" })
    local sum = code == 0 and out:match("^(%x+)")
    if not sum or #sum ~= SHA256_LENGTH then
        return nil, nil, Reason.HASH_FAILED, file
    end
    return sum:lower()
end

local CONNECT_TIMEOUT_SECS = "15"
local MAX_TIME_SECS = "600"

local function fetch_command(pin, file)
    return {
        "curl",
        "-fsSL",
        "--connect-timeout",
        CONNECT_TIMEOUT_SECS,
        "--max-time",
        MAX_TIME_SECS,
        "-o",
        file,
        pin.url,
    }
end

local function extract_command(pin, file, dir)
    local flags = archive_flags(pin.url)
    if flags then
        return { "tar", flags, file, "-C", dir }
    elseif is_zip(pin.url) then
        return { "unzip", "-q", "-o", file, "-d", dir }
    end
end

local function install_command(source, target)
    return { "install", "-m", "755", source, target }
end

local PLAN_DOWNLOAD, PLAN_EXTRACT = "<download>", "<extract>"

local function plan(pin)
    local lines = { lib.line(fetch_command(pin, PLAN_DOWNLOAD)) }
    local checksum = checksum_command(PLAN_DOWNLOAD) or { "shasum", "-a", "256", PLAN_DOWNLOAD }
    lines[#lines + 1] = lib.line(checksum) .. "  (expect " .. pin.sha256 .. ")"
    local source = PLAN_DOWNLOAD
    if is_archive(pin.url) then
        lines[#lines + 1] = lib.line(extract_command(pin, PLAN_DOWNLOAD, PLAN_EXTRACT))
        source = PLAN_EXTRACT .. "/" .. pin.path
    end
    return lines, source
end

local function dry_run(row, pin, dest)
    local lines, source = plan(pin)
    lines[#lines + 1] = lib.line(install_command(source, dest))
    return lib.dry_run(row, lines)
end

local function inside(real, dir)
    return real:sub(1, #dir + 1) == dir .. "/"
end

local function locate(pin, work)
    if pin.path == NO_PATH then
        return work.download
    end
    local source = fs.join(work.extract, pin.path)
    local real = fs.realpath(source)
    local root = fs.realpath(work.extract)
    if not real or not root or not inside(real, root) or not fs.is_file(real) then
        return nil, nil, Reason.NO_FILE, pin.path
    end
    return real
end

local function place(source, dest, opts)
    local staged = fs.join(fs.dirname(dest), "." .. fs.basename(dest) .. ".new")
    local ok = lib.run(install_command(source, staged), opts) == 0
        and lib.run({ "mv", "-f", staged, dest }, opts) == 0
    if not ok then
        fs.remove(staged)
    end
    return ok
end

local function fail(row, message)
    note("  ! " .. row.name .. ": " .. message)
    return 1
end

local function verify(pin, file)
    local actual, _, reason, detail = sha256_of(file)
    if not actual then
        fs.remove(file)
        return nil, nil, reason, detail
    elseif actual ~= pin.sha256 then
        fs.remove(file)
        return nil, nil, Reason.MISMATCH, actual
    end
    return true
end

local function unpack_pin(pin, work, opts)
    if lib.run(fetch_command(pin, work.download), opts) ~= 0 then
        return nil, nil, Reason.DOWNLOAD, pin.url
    end
    local verified, _, reason, detail = verify(pin, work.download)
    if not verified then
        return nil, nil, reason, detail
    end
    if is_archive(pin.url) then
        fs.mkdir(work.extract, { parents = true })
        if lib.run(extract_command(pin, work.download, work.extract), opts) ~= 0 then
            return nil, nil, Reason.EXTRACT, pin.url
        end
    end
    return locate(pin, work)
end

---The sentence writers by reason
local REFUSALS = {
    [Reason.NO_HASHER] = function()
        return "Neither shasum nor sha256sum is on PATH."
    end,
    [Reason.HASH_FAILED] = function(_, file)
        return "Could not read the sha256 of " .. file .. "."
    end,
    [Reason.MISMATCH] = function(pin, actual)
        return "The sha256 of "
            .. pin.url
            .. " does not match the pin. Expected "
            .. pin.sha256
            .. ", got "
            .. actual
            .. "."
    end,
    [Reason.NO_FILE] = function(_, path)
        return "The archive holds no file " .. path .. "."
    end,
    [Reason.DOWNLOAD] = function(_, url)
        return "Failed to download " .. url .. "."
    end,
    [Reason.EXTRACT] = function(_, url)
        return "Failed to extract " .. url .. "."
    end,
}

---Write the sentence for a reason that `fetch` returned.
---@param pin dev.pkg.release.Pin the pin that was fetched
---@param reason dev.pkg.release.Reason why the fetch refused
---@param detail string? the url, file or path the reason names, or the actual sum on a mismatch
---@return string sentence what to print for a person
function M.refusal(pin, reason, detail)
    return REFUSALS[reason](pin, detail)
end

local function steps(job, opts)
    local row, pin, dest, work = job.row, job.pin, job.dest, job.work
    local source, _, reason, detail = unpack_pin(pin, work, opts)
    if not source then
        return fail(row, M.refusal(pin, reason, detail))
    end
    local made, why = fs.mkdir(fs.dirname(dest), { parents = true })
    if not made then
        return fail(row, why or "Cannot make " .. fs.dirname(dest) .. ".")
    elseif not place(source, dest, opts) then
        return fail(row, "Failed to copy the binary to " .. dest .. ".")
    end
    return 0
end

local function download_and_install(row, pin, dest, opts)
    local dir, why = fs.mktemp({ prefix = "release", dir = true })
    if not dir then
        return fail(row, why or "Cannot make a temporary directory.")
    end
    local work = { download = fs.join(dir, "download"), extract = fs.join(dir, "extract") }
    local code = steps({ row = row, pin = pin, dest = dest, work = work }, opts)
    dev_os.run({ "chmod", "-R", "u+rwX", dir }, { stdout = "null", stderr = "null" })
    fs.remove(dir, { recursive = true })
    return code
end

---Download a pin, check its sha256 and unpack it, without installing anything.
---
---The checksum is verified before anything is extracted, and a mismatch removes the download.
---@param pin dev.pkg.release.Pin the pinned asset
---@param dir string an existing directory to work in
---@param opts { log_file: string? }? where the commands' output goes
---@return string? path the real path of the pin's file inside the unpacked archive, or of the bare
---   download
---@return nil message always nil, which keeps the slot a lower layer's message would take
---@return dev.pkg.release.Reason? reason why it failed, for `refusal`
---@return string? detail the url, file or path the reason names, or the actual sum on a mismatch
function M.fetch(pin, dir, opts)
    return unpack_pin(
        pin,
        { download = fs.join(dir, "download"), extract = fs.join(dir, "extract") },
        opts
    )
end

---List the commands `fetch` would run, as the text a dry run prints.
---@param pin dev.pkg.release.Pin the pinned asset
---@return string[] lines the download, checksum and unpack commands
---@return string path where the pin's file would be, under `<extract>`
M.plan = plan

---Print whether a release tool is present, as a line starting `[x]` or `[ ]`.
---
---A tool on PATH counts, and so does one in the bin directory when that is not on PATH.
---@param row dev.pkg.Row the tool, with the pin's name as its package
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return false
        end,
        elsewhere = function()
            local dir = bin_dir()
            local path = dir and fs.join(dir, target_name(row))
            return path and fs.is_exec(path) and path or nil
        end,
    })
end

---Install a pinned release asset into the bin directory unless the tool is present.
---
---The bin directory is `DEV_TOOLS_BIN`, else `~/.local/bin`. The download is checked against the
---pin's sha256 before anything is extracted, a mismatch removes it and the bin directory is
---untouched, and an archive is chosen by the url's suffix. Every word reaches a command as one
---argument.
---@param row dev.pkg.Row the tool, with the pin's name as its package
---@param opts dev.pkg.driver.install.Opts the flags and the pins file
---@return integer code 0 on success
function M.install(row, opts)
    local dir = bin_dir()
    if not dir then
        return fail(row, "No bin directory. Set DEV_TOOLS_BIN or HOME.")
    end
    local dest = fs.join(dir, target_name(row))
    if fs.is_dir(dest) then
        return fail(row, "A directory sits at " .. dest .. ".")
    end
    if not opts.force then
        if lib.skip_on_path(row) then
            return 0
        elseif fs.is_exec(dest) then
            return lib.skip(row, "already installed in " .. dir)
        end
    end
    local pins, err = M.read(opts.releases)
    if not pins then
        return fail(row, err)
    end
    local pin = pins[row.package]
    if not pin then
        return fail(row, "No pin named " .. row.package .. " in " .. opts.releases .. ".")
    end
    if opts.dry_run then
        return dry_run(row, pin, dest)
    end
    stdout:write("  + installing ", row.name, " (release ", pin.version, ")...\n")
    return download_and_install(row, pin, dest, opts)
end

return M

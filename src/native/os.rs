use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, BufRead, IsTerminal, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::result::Result as StdResult;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use std::{env, thread};

use mlua::{Function, Lua, LuaString, Table, Value, Variadic};

use crate::native::process::{self, Group, Sink, Spec};
use crate::native::signals;
use crate::{Error, Result, native_fn, overlay, runtime};

/// Name of this module under `dev`.
pub const NAME: &str = "os";

/// Name the stream methods are registered under.
const STREAM: &str = "os.stream";

/// Name the process methods are registered under.
const PROC: &str = "os.proc";

/// Registry slot of the `dev.os.defaults` table, which every spawn reads.
const DEFAULTS_KEY: &str = "dev.os.defaults";

/// Registry slot of the methods of a spawned process.
const PROC_METHODS_KEY: &str = "dev.os.proc";

/// Registry slot of the function that stops spawned processes when dev exits.
const STOP_KEY: &str = "dev.os.stop";

/// Whether the exit cleanup that stops spawned processes is registered.
static STOP_HOOKED: AtomicBool = AtomicBool::new(false);

/// Longest sleep `nap` takes, in seconds.
const MAX_NAP_SECS: f64 = 1e9;

/// The file kinds a mode names, by their file type bits, with the name of each.
const KINDS: [(i64, &str, &str); 3] = [
    (0x8000, "FILE", "file"),
    (0x4000, "DIR", "dir"),
    (0xA000, "LINK", "link"),
];

/// Name of every other kind of file.
const OTHER_KIND: (&str, &str) = ("OTHER", "other");

/// Stream value that discards the output or gives the child an empty input.
const NULL: &str = "null";

/// Stream value that leaves a stream as dev's own.
const INHERIT: &str = "inherit";

/// Stream value that sends standard error into standard output.
const STDOUT: &str = "stdout";

/// Stream value that is never valid, since standard output cannot merge into standard error.
const STDERR: &str = "stderr";

/// The file type bits of a mode.
const S_IFMT: i64 = 0xF000;

/// The random device `random_bytes` reads.
const RANDOM_DEVICE: &str = "/dev/urandom";

/// How long `nap` sleeps between looks for an interrupt.
const NAP_SLICE: Duration = Duration::from_millis(50);

/// Verbosity at which every spawn is written to standard error.
const SHOW_LEVEL: u8 = 2;

/// Start of the program, from which `monotonic` counts.
static START: OnceLock<Instant> = OnceLock::new();

/// Installs the handlers that turn SIGINT, SIGTERM and SIGHUP into a Luau interrupt.
pub fn install_signals() {
    signals::install();
}

native_fn! {
    /// Enters folder `path`, so dev and every program it starts afterwards run there.
    ///
    /// Returns true, or `nil` and the reason when the folder cannot be entered.
    ///
    /// # Errors
    ///
    /// Raises no Lua error of its own.
    pub fn chdir(_lua: &Lua, path: String) -> mlua::Result<StdResult<bool, String>> {
        Ok(enter(&path).map(|()| true).map_err(|error| error.to_string()))
    }
}

/// Makes `path` dev's working folder and sets `PWD` to it for the programs dev starts.
fn enter(path: &str) -> Result<()> {
    env::set_current_dir(path).map_err(|source| Error::io(format!("enter {path}"), source))?;
    let pwd = env::current_dir().map_err(|source| Error::io("read the working folder", source))?;
    overlay::set("PWD", Some(&pwd.display().to_string()));
    Ok(())
}

native_fn! {
    /// Returns the value of environment variable `name`, or `nil` when it is not set.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the string cannot be created.
    pub fn getenv(lua: &Lua, name: String) -> mlua::Result<Option<LuaString>> {
        if name.is_empty() || name.contains(['=', '\0']) {
            return Ok(None);
        }
        overlay::get(&name)
            .map(|value| lua.create_string(value.as_bytes()))
            .transpose()
    }
}

native_fn! {
    /// Sets environment variable `name` to `value`, or removes it when `value` is `nil`.
    ///
    /// # Errors
    ///
    /// Raises when `name` is empty or holds `=` or a NUL byte, or `value` holds a NUL byte.
    pub fn setenv(_lua: &Lua, name: String, value: Option<String>) -> mlua::Result<()> {
        if name.is_empty() || name.contains(['=', '\0']) {
            return Err(mlua::Error::runtime(format!(
                "bad argument #1 to 'setenv' (invalid variable name {name:?})"
            )));
        }
        if value.as_deref().is_some_and(|text| text.contains('\0')) {
            return Err(mlua::Error::runtime(
                "bad argument #2 to 'setenv' (value has a NUL byte)",
            ));
        }
        overlay::set(&name, value.as_deref());
        Ok(())
    }
}

native_fn! {
    /// Returns a copy of the environment, by variable name.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn vars(_lua: &Lua) -> mlua::Result<BTreeMap<String, String>> {
        Ok(overlay::vars())
    }
}

native_fn! {
    /// Names the operating system: `Darwin`, `Linux` or `Windows`.
    ///
    /// # Errors
    ///
    /// Never fails.
    #[luau = "() -> string"]
    pub fn name(_lua: &Lua) -> mlua::Result<String> {
        let name = match env::consts::OS {
            "macos" => "Darwin",
            "linux" => "Linux",
            "windows" => "Windows",
            other => other,
        };
        Ok(name.to_owned())
    }
}

native_fn! {
    /// Names the processor architecture, as Rust's target names it.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn arch(_lua: &Lua) -> mlua::Result<String> {
        Ok(env::consts::ARCH.to_owned())
    }
}

native_fn! {
    /// Returns the real user id of the process.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn getuid(_lua: &Lua) -> mlua::Result<u32> {
        Ok(rustix::process::getuid().as_raw())
    }
}

native_fn! {
    /// Returns the process id of dev.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn getpid(_lua: &Lua) -> mlua::Result<u32> {
        Ok(std::process::id())
    }
}

native_fn! {
    /// Returns whether descriptor `fd`, 0, 1 or 2, is a terminal.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn isatty(_lua: &Lua, fd: i32) -> mlua::Result<bool> {
        Ok(match fd {
            0 => io::stdin().is_terminal(),
            1 => io::stdout().is_terminal(),
            2 => io::stderr().is_terminal(),
            _ => false,
        })
    }
}

native_fn! {
    /// Sleeps for `secs` seconds, which may be a fraction, and wakes early on an interrupt.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn nap(_lua: &Lua, secs: f64) -> mlua::Result<()> {
        let deadline = Instant::now() + Duration::from_secs_f64(secs.clamp(0.0, MAX_NAP_SECS));
        while !runtime::interrupted() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            thread::sleep(left.min(NAP_SLICE));
        }
        Ok(())
    }
}

native_fn! {
    /// Returns seconds from a clock that never goes back.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn monotonic(_lua: &Lua) -> mlua::Result<f64> {
        Ok(START.get_or_init(Instant::now).elapsed().as_secs_f64())
    }
}

native_fn! {
    /// Reads exactly `count` random bytes, or returns `nil` and the reason.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the string cannot be created.
    pub fn random_bytes(lua: &Lua, count: usize) -> mlua::Result<StdResult<LuaString, String>> {
        let mut bytes = vec![0u8; count];
        let read = File::open(RANDOM_DEVICE).and_then(|mut device| device.read_exact(&mut bytes));
        match read {
            Ok(()) => Ok(Ok(lua.create_string(&bytes)?)),
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(Err(format!(
                "The random device {RANDOM_DEVICE} returned too few bytes."
            ))),
            Err(error) => Ok(Err(process::reason(&Error::io("read the random device", error)))),
        }
    }
}

native_fn! {
    /// Adds `dirs` to the end of PATH, so a tool already on PATH still wins.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn append_path(_lua: &Lua, dirs: Vec<String>) -> mlua::Result<()> {
        if dirs.is_empty() {
            return Ok(());
        }
        let added = dirs.join(":");
        let path = match overlay::get("PATH") {
            Some(old) if !old.is_empty() => format!("{old}:{added}"),
            _ => added,
        };
        overlay::set("PATH", Some(&path));
        Ok(())
    }
}

native_fn! {
    /// Finds `name` on PATH and returns its absolute path, or `nil` when there is none.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn which(_lua: &Lua, name: String) -> mlua::Result<Option<String>> {
        Ok(find_program(&name).map(|path| path.to_string_lossy().into_owned()))
    }
}

/// Returns the absolute path of the executable file `name` names, searching PATH when it has no slash.
fn find_program(name: &str) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    let cwd = env::current_dir().ok()?;
    if name.contains('/') {
        return executable(&cwd.join(name));
    }
    let path = overlay::get("PATH")?;
    env::split_paths(&path)
        .map(|dir| {
            cwd.join(if dir.as_os_str().is_empty() {
                Path::new(".")
            } else {
                &dir
            })
        })
        .find_map(|dir| executable(&dir.join(name)))
}

/// Returns `path` when it is a file someone may run.
fn executable(path: &Path) -> Option<PathBuf> {
    let meta = fs::metadata(path).ok()?;
    (meta.is_file() && meta.permissions().mode() & 0o111 != 0).then(|| path.to_path_buf())
}

/// Quotes `arg` as one shell word.
fn quote_bytes(arg: &[u8]) -> Vec<u8> {
    let mut word = vec![b'\''];
    for byte in arg {
        if *byte == b'\'' {
            word.extend_from_slice(b"'\\''");
        } else {
            word.push(*byte);
        }
    }
    word.push(b'\'');
    word
}

native_fn! {
    /// Quotes `arg` as one shell word in single quotes.
    ///
    /// # Errors
    ///
    /// Raises when `arg` is not a string or holds a NUL byte.
    #[luau = "(arg: string) -> string"]
    pub fn quote(lua: &Lua, arg: Value) -> mlua::Result<LuaString> {
        let Value::String(text) = arg else {
            return Err(mlua::Error::runtime(format!(
                "quote expects a string, got {}",
                arg.type_name()
            )));
        };
        let bytes = text.as_bytes();
        if bytes.contains(&0) {
            return Err(mlua::Error::runtime(
                "quote cannot take an argument with a NUL byte",
            ));
        }
        lua.create_string(quote_bytes(&bytes))
    }
}

native_fn! {
    /// Joins `argv` into one shell command with every word quoted.
    ///
    /// # Errors
    ///
    /// Raises when `argv` is empty or a word holds a NUL byte.
    pub fn command(lua: &Lua, argv: Value) -> mlua::Result<LuaString> {
        let Value::Table(table) = argv else {
            return Err(mlua::Error::runtime("command expects a non-empty argv list"));
        };
        let words: Vec<LuaString> = table.sequence_values().collect::<mlua::Result<_>>()?;
        if words.is_empty() {
            return Err(mlua::Error::runtime("command expects a non-empty argv list"));
        }
        let mut line = Vec::new();
        for (index, word) in words.iter().enumerate() {
            let bytes = word.as_bytes();
            if bytes.contains(&0) {
                return Err(mlua::Error::runtime(
                    "quote cannot take an argument with a NUL byte",
                ));
            }
            if index > 0 {
                line.push(b' ');
            }
            line.extend(quote_bytes(&bytes));
        }
        lua.create_string(line)
    }
}

native_fn! {
    /// Names the kind of file a raw `st_mode` describes: `file`, `dir`, `link` or `other`.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn kind_of(_lua: &Lua, mode: i64) -> mlua::Result<String> {
        let kind = KINDS
            .iter()
            .find(|(bits, _, _)| *bits == mode & S_IFMT)
            .map_or(OTHER_KIND.1, |(_, _, name)| name);
        Ok((*kind).to_owned())
    }
}

/// Describes a Luau value as a variable name in an error.
fn describe(value: &Value) -> String {
    match value {
        Value::String(text) => text.to_string_lossy(),
        Value::Integer(number) => number.to_string(),
        Value::Number(number) => number.to_string(),
        other => other.type_name().to_owned(),
    }
}

/// Returns whether `name` is a valid variable name.
fn valid_name(name: &[u8]) -> bool {
    let mut bytes = name.iter();
    matches!(bytes.next(), Some(b'A'..=b'Z' | b'a'..=b'z' | b'_'))
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
}

/// Raises the error for an invalid variable name.
fn bad_name(name: &str) -> mlua::Error {
    mlua::Error::runtime(format!("env name {name} is not a valid variable name"))
}

/// Reads an environment table into name and value bytes.
fn read_env(table: Option<Table>) -> mlua::Result<Vec<(Vec<u8>, Vec<u8>)>> {
    let mut pairs = Vec::new();
    let Some(table) = table else {
        return Ok(pairs);
    };
    for pair in table.pairs::<Value, Value>() {
        let (name, value) = pair?;
        let Value::String(name_text) = &name else {
            return Err(bad_name(&describe(&name)));
        };
        let text = match &value {
            Value::String(text) => text.as_bytes().to_vec(),
            Value::Integer(number) => number.to_string().into_bytes(),
            Value::Number(number) => number.to_string().into_bytes(),
            other => {
                return Err(mlua::Error::runtime(format!(
                    "env value of {} must be a string, got {}",
                    name_text.to_string_lossy(),
                    other.type_name()
                )));
            }
        };
        pairs.push((name_text.as_bytes().to_vec(), text));
    }
    Ok(pairs)
}

/// Reads a list of variable names.
fn read_names(table: Option<Table>) -> mlua::Result<Vec<Vec<u8>>> {
    let Some(table) = table else {
        return Ok(Vec::new());
    };
    table
        .sequence_values::<LuaString>()
        .map(|name| name.map(|text| text.as_bytes().to_vec()))
        .collect()
}

/// Turns a stream option into a sink.
fn sink_of(text: Option<String>, merge: Option<&str>) -> Sink {
    match text.as_deref() {
        None | Some(INHERIT) => Sink::Inherit,
        Some(NULL) => Sink::Null,
        Some(word) if Some(word) == merge => Sink::Merge,
        Some(path) => Sink::Append(PathBuf::from(path)),
    }
}

/// Builds the command to start from `argv` and the options table `opts`.
///
/// `who` names the function in errors, and `streams` says whether the stream options count.
fn spec_of(
    lua: &Lua,
    who: &str,
    argv: &[LuaString],
    opts: Option<&Table>,
    streams: bool,
) -> mlua::Result<Spec> {
    if argv.is_empty() {
        return Err(mlua::Error::runtime(format!(
            "{who} expects a non-empty argv list"
        )));
    }
    let mut words = Vec::new();
    for word in argv {
        let bytes = word.as_bytes();
        if bytes.contains(&0) {
            return Err(mlua::Error::runtime(format!(
                "{who} cannot take an argument with a NUL byte"
            )));
        }
        words.push(OsString::from_vec(bytes.to_vec()));
    }
    let defaults: Table = lua.named_registry_value(DEFAULTS_KEY)?;
    let mut merged: BTreeMap<Vec<u8>, Vec<u8>> =
        read_env(defaults.get("env")?)?.into_iter().collect();
    let mut unset = read_names(defaults.get("unset")?)?;
    for name in &unset {
        merged.remove(name);
    }
    let own_unset = match opts {
        Some(opts) => read_names(opts.get("unset")?)?,
        None => Vec::new(),
    };
    if let Some(opts) = opts {
        merged.extend(read_env(opts.get("env")?)?);
    }
    for name in &own_unset {
        merged.remove(name);
    }
    unset.extend(own_unset);
    for name in merged.keys().chain(&unset) {
        if !valid_name(name) {
            return Err(bad_name(&String::from_utf8_lossy(name)));
        }
    }
    let mut spec = Spec {
        argv: words,
        env_set: merged
            .into_iter()
            .map(|(name, value)| (OsString::from_vec(name), OsString::from_vec(value)))
            .collect(),
        env_unset: unset.into_iter().map(OsString::from_vec).collect(),
        ..Spec::default()
    };
    let Some(opts) = opts else {
        return Ok(spec);
    };
    spec.cwd = opts.get::<Option<String>>("cwd")?.map(PathBuf::from);
    if !streams {
        return Ok(spec);
    }
    let stdin: Option<String> = opts.get("stdin")?;
    let stdout: Option<String> = opts.get("stdout")?;
    let stderr: Option<String> = opts.get("stderr")?;
    if stdin.as_deref().is_some_and(|word| word != NULL) {
        return Err(mlua::Error::runtime(r#"stdin must be "null" or unset"#));
    }
    if matches!(stdout.as_deref(), Some(STDOUT | STDERR)) || stderr.as_deref() == Some(STDERR) {
        return Err(mlua::Error::runtime(
            "only stderr can merge, and only into stdout",
        ));
    }
    spec.null_stdin = stdin.is_some();
    spec.stdout = sink_of(stdout, None);
    spec.stderr = sink_of(stderr, Some(STDOUT));
    Ok(spec)
}

/// Returns argv from a Luau list.
fn argv_of(argv: &Table) -> mlua::Result<Vec<LuaString>> {
    argv.sequence_values().collect()
}

/// Returns the verbosity level of this run.
fn level(lua: &Lua) -> u8 {
    runtime::require(lua, "@dev/globals")
        .ok()
        .and_then(|value| value.as_table().cloned())
        .and_then(|table| table.get::<Option<u8>>("level").ok().flatten())
        .unwrap_or(0)
}

/// Writes the command to standard error when `defaults.show` or the verbosity asks for it.
fn announce(lua: &Lua, spec: &Spec) -> mlua::Result<()> {
    let defaults: Table = lua.named_registry_value(DEFAULTS_KEY)?;
    let show = defaults.get::<Option<bool>>("show")?.unwrap_or(false);
    if show || level(lua) >= SHOW_LEVEL {
        let mut line = b"+ ".to_vec();
        for (index, word) in spec.argv.iter().enumerate() {
            if index > 0 {
                line.push(b' ');
            }
            line.extend(quote_bytes(word.as_bytes()));
        }
        line.push(b'\n');
        runtime::write_err(&line);
    }
    Ok(())
}

/// Announces the command and flushes dev's streams, ahead of a spawn.
fn prepare(lua: &Lua, spec: &Spec) -> mlua::Result<()> {
    announce(lua, spec)?;
    runtime::flush_out(lua)
}

/// Reports a command that could not run and returns the status a shell gives.
fn could_not_run(spec: &Spec, error: &Error) -> i32 {
    let program = spec.argv[0].to_string_lossy();
    runtime::write_err(
        format!(
            "The command `{program}` could not run: {}.\n",
            process::reason(error)
        )
        .as_bytes(),
    );
    process::failed_code(error)
}

/// Returns the reason a spawn failed, naming the program.
fn named_reason(spec: &Spec, error: &Error) -> String {
    format!(
        "{}: {}",
        spec.argv[0].to_string_lossy(),
        process::reason(error)
    )
}

native_fn! {
    /// Runs `argv` with the terminal's streams and returns its exit status.
    ///
    /// A command killed by a signal gives 128 plus the signal. A command that cannot start gives
    /// 127 or 126 after a message on standard error.
    ///
    /// # Errors
    ///
    /// Raises on a bad option or a NUL byte in a word.
    #[luau = "(argv: { string }, opts: { [any]: any }?) -> number"]
    pub fn run(lua: &Lua, argv: Table, opts: Option<Table>) -> mlua::Result<i32> {
        let spec = spec_of(lua, "run", &argv_of(&argv)?, opts.as_ref(), true)?;
        prepare(lua, &spec)?;
        match process::run(&spec) {
            Ok(code) => Ok(code),
            Err(error @ Error::Io { .. }) => Ok(could_not_run(&spec, &error)),
            Err(error) => Err(error.into()),
        }
    }
}

/// Starts `spec` and collects its output, turning a failure to start into a status.
fn collect(lua: &Lua, spec: &Spec, input: Option<&[u8]>) -> mlua::Result<(LuaString, i32)> {
    prepare(lua, spec)?;
    match process::capture(spec, input) {
        Ok((out, code)) => Ok((lua.create_string(out)?, code)),
        Err(error @ Error::Io { .. }) => Ok((lua.create_string("")?, could_not_run(spec, &error))),
        Err(error) => Err(error.into()),
    }
}

native_fn! {
    /// Runs `argv` and returns its standard output and exit status.
    ///
    /// # Errors
    ///
    /// Raises on a bad option or a NUL byte in a word.
    #[luau = "(argv: { string }, opts: { [any]: any }?) -> (string, number)"]
    pub fn capture(lua: &Lua, argv: Table, opts: Option<Table>) -> mlua::Result<(LuaString, i32)> {
        let spec = spec_of(lua, "capture", &argv_of(&argv)?, opts.as_ref(), true)?;
        collect(lua, &spec, None)
    }
}

native_fn! {
    /// Runs `argv` with `input` on its standard input and returns its standard output and status.
    ///
    /// The input travels through a pipe, never an argument list, an environment or a file.
    ///
    /// # Errors
    ///
    /// Raises on a bad option, a NUL byte in a word, or when `opts` sets `stdin` or `stdout`.
    #[luau = "(argv: { string }, input: string, opts: { [any]: any }?) -> (string, number)"]
    pub fn capture_input(
        lua: &Lua,
        argv: Table,
        input: LuaString,
        opts: Option<Table>,
    ) -> mlua::Result<(LuaString, i32)> {
        if let Some(opts) = &opts
            && (!opts.get::<Value>("stdin")?.is_nil() || !opts.get::<Value>("stdout")?.is_nil())
        {
            return Err(mlua::Error::runtime(
                "capture_input takes the input as an argument and keeps standard output",
            ));
        }
        let spec = spec_of(lua, "capture_input", &argv_of(&argv)?, opts.as_ref(), true)?;
        collect(lua, &spec, Some(&input.as_bytes()))
    }
}

native_fn! {
    /// Runs `argv` in its own process group and collects its output, stopping it after `secs`.
    ///
    /// A command that outlives the limit is sent TERM and then KILL together with everything it
    /// started, and the status is 124. A `secs` of 0 or less sets no limit. The options are `env`,
    /// `unset`, `cwd`, `input`, `merge`, `stderr` ("null", "inherit" or a path), `reap` and `on_text`.
    ///
    /// # Errors
    ///
    /// Raises on a bad option, a NUL byte in a word, when the command cannot start, or with the
    /// error `on_text` raised.
    #[luau = "(argv: { string }, secs: number, opts: { [any]: any }?) -> (string, number)"]
    pub fn capture_timed(
        lua: &Lua,
        argv: Table,
        secs: f64,
        opts: Option<Table>,
    ) -> mlua::Result<(LuaString, i32)> {
        let mut spec = spec_of(lua, "capture_timed", &argv_of(&argv)?, opts.as_ref(), false)?;
        spec.group = Group::Own;
        let mut input = None;
        let mut reap = false;
        let mut on_text: Option<Function> = None;
        if let Some(opts) = &opts {
            input = opts.get::<Option<LuaString>>("input")?.map(|text| text.as_bytes().to_vec());
            reap = opts.get::<Option<bool>>("reap")?.unwrap_or(false);
            on_text = opts.get("on_text")?;
            spec.stderr = sink_of(opts.get::<Option<String>>("stderr")?, None);
            if opts.get::<Option<bool>>("merge")?.unwrap_or(false) {
                spec.stderr = Sink::Merge;
            }
        }
        spec.null_stdin = input.is_none();
        prepare(lua, &spec)?;
        let mut deliver = |chunk: &[u8]| match &on_text {
            Some(callback) => lua
                .create_string(chunk)
                .and_then(|text| callback.call::<()>(text))
                .map_err(|error| Error::Message(runtime::message(&error))),
            None => Ok(()),
        };
        match process::capture_timed(&spec, secs, input.as_deref(), reap, &mut deliver) {
            Ok((out, code)) => Ok((lua.create_string(out)?, code)),
            Err(error @ Error::Io { .. }) => {
                Ok((lua.create_string("")?, could_not_run(&spec, &error)))
            }
            Err(error) => Err(error.into()),
        }
    }
}

native_fn! {
    /// Replaces dev with `argv`, and returns `nil` and a reason only when that fails.
    ///
    /// # Errors
    ///
    /// Raises on a bad option or a NUL byte in a word.
    #[luau = "(argv: { string }, opts: { [any]: any }?) -> (nil, string)"]
    pub fn exec(lua: &Lua, argv: Table, opts: Option<Table>) -> mlua::Result<(Option<bool>, String)> {
        let spec = spec_of(lua, "exec", &argv_of(&argv)?, opts.as_ref(), true)?;
        prepare(lua, &spec)?;
        let error = match spec.command(spec.input(), None) {
            Ok(mut command) => Error::io("start the command", command.exec()),
            Err(error) => error,
        };
        Ok((None, process::reason(&error)))
    }
}

native_fn! {
    /// Starts `argv` without waiting and returns a process with `pid`, `wait` and `kill`.
    ///
    /// The command leads its own process group. With `detach` it survives dev, and any other
    /// spawned command is stopped when dev exits. On failure it returns `nil` and a reason naming
    /// the program.
    ///
    /// # Errors
    ///
    /// Raises on a bad option or a NUL byte in a word.
    #[luau = "(argv: { string }, opts: { [any]: any }?) -> ({ pid: number, wait: (self: any, secs: number?) -> number?, kill: (self: any, signal: (number | string)?) -> boolean }?, string?)"]
    pub fn spawn(
        lua: &Lua,
        argv: Table,
        opts: Option<Table>,
    ) -> mlua::Result<StdResult<Table, String>> {
        let mut spec = spec_of(lua, "spawn", &argv_of(&argv)?, opts.as_ref(), true)?;
        let detach = match &opts {
            Some(opts) => opts.get::<Option<bool>>("detach")?.unwrap_or(false),
            None => false,
        };
        spec.group = Group::Own;
        if detach {
            spec.null_stdin = true;
            if spec.stdout == Sink::Inherit {
                spec.stdout = Sink::Null;
            }
            if spec.stderr == Sink::Inherit {
                spec.stderr = Sink::Null;
            }
        }
        prepare(lua, &spec)?;
        let pid = match process::spawn(&spec, detach) {
            Ok(pid) => pid,
            Err(error) => return Ok(Err(named_reason(&spec, &error))),
        };
        if !STOP_HOOKED.swap(true, Ordering::SeqCst) {
            runtime::on_exit(lua, lua.named_registry_value(STOP_KEY)?)?;
        }
        let methods: Table = lua.named_registry_value(PROC_METHODS_KEY)?;
        Ok(Ok(object(lua, &methods, "pid", pid)?))
    }
}

/// Makes a table holding `field` that reads its methods from `methods`.
fn object(lua: &Lua, methods: &Table, field: &str, value: u32) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set(field, value)?;
    let meta = lua.create_table()?;
    meta.set("__index", methods.clone())?;
    table.set_metatable(Some(meta))?;
    Ok(table)
}

native_fn! {
    /// Waits for a spawned process and returns its exit status, or `nil` while it still runs.
    ///
    /// With `secs` it waits at most that long, and without it until the process ends or dev is
    /// interrupted.
    ///
    /// # Errors
    ///
    /// Raises when `this` is not a process.
    pub fn wait(_lua: &Lua, this: Table, secs: Option<f64>) -> mlua::Result<Option<i32>> {
        let pid: u32 = this.get("pid")?;
        Ok(process::wait(pid, secs).flatten())
    }
}

native_fn! {
    /// Stops every spawned process that is not detached. Runs when dev exits.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn stop_spawned(_lua: &Lua) -> mlua::Result<()> {
        process::stop_spawned();
        Ok(())
    }
}

/// Reads a signal number from a number or a name such as `TERM` or `SIGTERM`.
fn signal_of(value: Option<Value>) -> mlua::Result<i32> {
    match value {
        None | Some(Value::Nil) => Ok(signals::TERM),
        Some(Value::Integer(number)) => i32::try_from(number)
            .map_err(|_| mlua::Error::runtime("bad argument #1 to 'kill' (signal out of range)")),
        Some(Value::Number(number)) if number.fract() == 0.0 => Ok(number as i32),
        Some(Value::String(name)) => {
            let text = name.to_string_lossy();
            signals::by_name(&text).ok_or_else(|| {
                mlua::Error::runtime(format!("bad argument #1 to 'kill' (unknown signal {text})"))
            })
        }
        Some(other) => Err(mlua::Error::runtime(format!(
            "bad argument #1 to 'kill' (number or string expected, got {})",
            other.type_name()
        ))),
    }
}

native_fn! {
    /// Sends `signal`, `TERM` by default, to the process group of a spawned process.
    ///
    /// # Errors
    ///
    /// Raises when `this` is not a process or the signal is not known.
    pub fn kill(_lua: &Lua, this: Table, signal: Option<Value>) -> mlua::Result<bool> {
        let pid: u32 = this.get("pid")?;
        Ok(process::kill(pid, signal_of(signal)?))
    }
}

/// Returns the text of a Luau value written to a stream.
fn text_of(value: &Value, position: usize) -> mlua::Result<Vec<u8>> {
    match value {
        Value::String(text) => Ok(text.as_bytes().to_vec()),
        Value::Integer(number) => Ok(number.to_string().into_bytes()),
        Value::Number(number) => Ok(number.to_string().into_bytes()),
        other => Err(mlua::Error::runtime(format!(
            "bad argument #{position} to 'write' (string expected, got {})",
            other.type_name()
        ))),
    }
}

native_fn! {
    /// Writes each value to the stream and returns the stream.
    ///
    /// # Errors
    ///
    /// Raises for a value that is not a string or number, and when the write fails.
    pub fn write(lua: &Lua, this: Table, parts: Variadic<Value>) -> mlua::Result<Table> {
        let mut bytes = Vec::new();
        for (index, part) in parts.iter().enumerate() {
            bytes.extend(text_of(part, index + 1)?);
        }
        if this.get::<i32>("fd")? == 2 {
            runtime::write_err(&bytes);
        } else {
            runtime::write_out(lua, &bytes)?;
        }
        Ok(this)
    }
}

native_fn! {
    /// Writes out what the stream holds back and returns the stream.
    ///
    /// # Errors
    ///
    /// Raises when the write fails.
    pub fn flush(lua: &Lua, this: Table) -> mlua::Result<Table> {
        if this.get::<i32>("fd")? != 2 {
            runtime::flush_out(lua)?;
        }
        Ok(this)
    }
}

native_fn! {
    /// Reads standard input: all of it with `*a`, or one line with `*l`, the default.
    ///
    /// A line has no newline, and `nil` marks the end of input. `*a` gives an empty string at the
    /// end.
    ///
    /// # Errors
    ///
    /// Raises for an unknown format or a failed read.
    pub fn read(lua: &Lua, _this: Table, format: Option<String>) -> mlua::Result<Option<LuaString>> {
        let format = format.unwrap_or_else(|| "*l".to_owned());
        let mut stdin = io::stdin().lock();
        let mut bytes = Vec::new();
        match format.trim_start_matches('*') {
            "a" => {
                stdin.read_to_end(&mut bytes).map_err(mlua::Error::external)?;
            }
            "l" => {
                let count = stdin.read_until(b'\n', &mut bytes).map_err(mlua::Error::external)?;
                if count == 0 {
                    return Ok(None);
                }
                if bytes.last() == Some(&b'\n') {
                    bytes.pop();
                }
            }
            _ => {
                return Err(mlua::Error::runtime(format!(
                    "bad argument #1 to 'read' (invalid format {format})"
                )));
            }
        }
        lua.create_string(bytes).map(Some)
    }
}

/// Makes a stream table for descriptor `fd` that reads its methods from `methods`.
fn stream(lua: &Lua, methods: &Table, fd: i32) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("fd", fd)?;
    let meta = lua.create_table()?;
    meta.set("__index", methods.clone())?;
    table.set_metatable(Some(meta))?;
    Ok(table)
}

/// Creates the `dev.os` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    chdir::register(lua, NAME, &table)?;
    getenv::register(lua, NAME, &table)?;
    setenv::register(lua, NAME, &table)?;
    vars::register(lua, NAME, &table)?;
    name::register(lua, NAME, &table)?;
    arch::register(lua, NAME, &table)?;
    getuid::register(lua, NAME, &table)?;
    getpid::register(lua, NAME, &table)?;
    isatty::register(lua, NAME, &table)?;
    nap::register(lua, NAME, &table)?;
    monotonic::register(lua, NAME, &table)?;
    random_bytes::register(lua, NAME, &table)?;
    append_path::register(lua, NAME, &table)?;
    which::register(lua, NAME, &table)?;
    quote::register(lua, NAME, &table)?;
    command::register(lua, NAME, &table)?;
    kind_of::register(lua, NAME, &table)?;
    run::register(lua, NAME, &table)?;
    capture::register(lua, NAME, &table)?;
    capture_input::register(lua, NAME, &table)?;
    capture_timed::register(lua, NAME, &table)?;
    exec::register(lua, NAME, &table)?;
    spawn::register(lua, NAME, &table)?;

    let kinds = lua.create_table()?;
    for (_, key, value) in KINDS {
        kinds.set(key, value)?;
    }
    kinds.set(OTHER_KIND.0, OTHER_KIND.1)?;
    table.set("Kind", kinds)?;

    let defaults = lua.create_table()?;
    defaults.set("env", lua.create_table()?)?;
    defaults.set("unset", lua.create_table()?)?;
    defaults.set("show", false)?;
    lua.set_named_registry_value(DEFAULTS_KEY, defaults.clone())?;
    table.set("defaults", defaults)?;

    let proc_methods = lua.create_table()?;
    wait::register(lua, PROC, &proc_methods)?;
    kill::register(lua, PROC, &proc_methods)?;
    lua.set_named_registry_value(PROC_METHODS_KEY, proc_methods)?;
    let exit_hook = lua.create_table()?;
    stop_spawned::register(lua, PROC, &exit_hook)?;
    lua.set_named_registry_value(STOP_KEY, exit_hook.get::<Function>("stop_spawned")?)?;

    let writer = lua.create_table()?;
    write::register(lua, STREAM, &writer)?;
    flush::register(lua, STREAM, &writer)?;
    table.set("stdout", stream(lua, &writer, 1)?)?;
    table.set("stderr", stream(lua, &writer, 2)?)?;
    let reader = lua.create_table()?;
    read::register(lua, STREAM, &reader)?;
    table.set("stdin", stream(lua, &reader, 0)?)?;
    Ok(table)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::io;

    use super::{Error, Spec, find_program, named_reason, quote_bytes, valid_name};

    #[test]
    fn quote_bytes_should_escape_single_quotes() {
        assert_eq!(quote_bytes(b"it's"), b"'it'\\''s'");
    }

    #[test]
    fn valid_name_should_refuse_a_name_with_a_dash_or_a_digit_first() {
        assert!(valid_name(b"_A1"));
        assert!(!valid_name(b"1A"));
        assert!(!valid_name(b"A-B"));
        assert!(!valid_name(b""));
    }

    #[test]
    fn find_program_should_find_sh_and_miss_a_made_up_name() {
        assert!(find_program("sh").is_some_and(|path| path.is_absolute()));
        assert!(find_program("no-such-program-anywhere").is_none());
    }

    #[test]
    fn named_reason_should_name_the_program() {
        let spec = Spec {
            argv: vec![OsString::from("nope")],
            ..Spec::default()
        };
        let error = Error::io("start nope", io::Error::from_raw_os_error(2));
        assert!(named_reason(&spec, &error).starts_with("nope: "));
    }
}

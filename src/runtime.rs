use std::collections::HashSet;
use std::io::{self, ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock};
use std::{fs, process};

use mlua::{Error, Function, Lua, LuaString, MultiValue, Table, Value, VmState};

use crate::native::signals::{INT as SIGINT, PIPE as SIGPIPE};
use crate::resolve::{DEV_ALIAS, Target, resolve};
use crate::{Error as DevError, embed, log};

/// Exit status of a process killed by signal n, which is this plus n.
pub const SIGNAL_EXIT_BASE: i32 = 128;

/// Exit status when a command cannot be started.
pub const EXEC_FAILED: i32 = 126;

/// Exit status after a write to a closed standard output, the status a kill by SIGPIPE gives.
pub const BROKEN_PIPE_EXIT: i32 = SIGNAL_EXIT_BASE + SIGPIPE;

/// Error text an interrupt raises in Luau, the text dev's Luau code matches.
pub const INTERRUPTED_MESSAGE: &str = "interrupted!";

/// Exit status of a run that failed.
pub const FAILURE_EXIT: i32 = 1;

/// Named registry slot of the table `require` caches modules in.
const LOADED_KEY: &str = "dev.loaded";

/// Named registry slot of the native module tables, keyed by module name.
const NATIVES_KEY: &str = "dev.natives";

/// Named registry slot of the cleanup functions, oldest first.
const CLEANUPS_KEY: &str = "dev.cleanups";

/// Registry key of the function that wraps a module function to trace its calls.
const MODULE_CALL_WRAP_KEY: &str = "dev.module_call_wrap";

/// Luau that, given the trace function, returns `wrap(name, f)`: `f` tracing `name` before each
/// call, or `f` itself when it is already such a wrapper, so a re-exported table is traced once.
const MODULE_CALL_WRAPPER: &str = "local trace = ...
local wrappers = setmetatable({}, { __mode = \"k\" })
return function(name, f)
    if wrappers[f] then
        return f
    end
    local function wrapper(...)
        trace(name)
        return f(...)
    end
    wrappers[wrapper] = true
    return wrapper
end
";

/// Folder of the embedded tree that holds dev's Luau modules.
const EMBEDDED_MODULES: &str = "luau/dev";

/// Number of a signal that arrived and that Luau has not raised yet, 0 for none.
///
/// signal-hook's `flag::register_usize` writes it from the signal handler, so it is shared.
static PENDING: LazyLock<Arc<AtomicUsize>> = LazyLock::new(|| Arc::new(AtomicUsize::new(0)));

/// Number of the last signal that interrupted dev, 0 for none.
static SIGNAL: AtomicI32 = AtomicI32::new(0);

/// Whether the interrupt hook has raised [`INTERRUPTED_MESSAGE`] in Luau.
static RAISED: AtomicBool = AtomicBool::new(false);

/// Whether standard output's reader went away, after which output is dropped.
static PIPE_CLOSED: AtomicBool = AtomicBool::new(false);

/// Module state kept beside the Lua state.
#[derive(Debug, Default)]
struct SearchState {
    /// Modules whose chunk is running, to catch a require loop.
    loading: HashSet<String>,
}

/// Creates the one Lua state dev runs in, with dev's `require`, `print` and interrupt hook.
///
/// # Errors
///
/// Returns the Lua error when a global or registry table cannot be set.
pub fn new() -> mlua::Result<Lua> {
    let lua = Lua::new();
    lua.set_app_data(SearchState::default());
    lua.set_named_registry_value(LOADED_KEY, lua.create_table()?)?;
    lua.set_named_registry_value(NATIVES_KEY, lua.create_table()?)?;
    lua.set_named_registry_value(CLEANUPS_KEY, lua.create_table()?)?;

    // Replace the globals whose stock versions bypass dev's module tree and output buffer
    let globals = lua.globals();
    globals.set(
        "require",
        lua.create_function(|lua, name: String| require_from(lua, &name, &caller_folder(lua)))?,
    )?;
    let tostring: Function = globals.get("tostring")?;
    let print =
        lua.create_function(move |lua, values: MultiValue| print(lua, &tostring, values))?;
    globals.set("print", print)?;

    lua.set_interrupt(|_| check_interrupt().map(|()| VmState::Continue));
    Ok(lua)
}

/// Records that `signal` arrived, so Luau raises [`INTERRUPTED_MESSAGE`] at its next instruction.
pub fn interrupt(signal: i32) {
    SIGNAL.store(signal, Ordering::SeqCst);
    PENDING.store(usize::try_from(signal).unwrap_or(1), Ordering::SeqCst);
}

/// Returns whether an interrupt arrived that Luau has not raised yet.
///
/// A blocking native call polls it, and returns [`check_interrupt`]'s error once it is true.
#[must_use]
pub fn interrupted() -> bool {
    PENDING.load(Ordering::SeqCst) != 0
}

/// Raises [`INTERRUPTED_MESSAGE`] when an interrupt arrived, the way the interrupt hook does.
///
/// # Errors
///
/// Returns the interrupt error, which [`is_interrupt`] recognizes, when one is pending.
pub fn check_interrupt() -> mlua::Result<()> {
    let signal = PENDING.swap(0, Ordering::SeqCst);
    if signal == 0 {
        return Ok(());
    }
    SIGNAL.store(i32::try_from(signal).unwrap_or(SIGINT), Ordering::SeqCst);
    RAISED.store(true, Ordering::SeqCst);
    Err(Error::runtime(INTERRUPTED_MESSAGE))
}

/// Returns the slot a signal handler stores its signal number in to interrupt Luau.
///
/// Pass it to `signal_hook::flag::register_usize(SIG, interrupt_slot(), SIG as usize)`.
#[must_use]
pub fn interrupt_slot() -> Arc<AtomicUsize> {
    Arc::clone(&PENDING)
}

/// Returns the exit status for an interrupt: 128 plus the signal still pending, else the one Luau
/// last raised, else SIGINT.
#[must_use]
pub fn interrupt_code() -> i32 {
    let pending = i32::try_from(PENDING.load(Ordering::SeqCst)).unwrap_or(SIGINT);
    let signal = if pending == 0 {
        SIGNAL.load(Ordering::SeqCst)
    } else {
        pending
    };
    match signal {
        0 => SIGNAL_EXIT_BASE + SIGINT,
        signal => SIGNAL_EXIT_BASE + signal,
    }
}

/// Returns whether `error` is the interrupt error, however Luau wrapped it.
///
/// An error only counts once the hook has raised one, so a Luau error that merely quotes the
/// text is reported as itself.
#[must_use]
pub fn is_interrupt(error: &Error) -> bool {
    RAISED.load(Ordering::SeqCst) && message(error).ends_with(INTERRUPTED_MESSAGE)
}

/// Returns the exit status a Luau value asks for: its integer value for a number, else `None`.
#[must_use]
pub fn exit_status(value: &Value) -> Option<i32> {
    match value {
        Value::Integer(code) => Some(i32::try_from(*code).unwrap_or(FAILURE_EXIT)),
        Value::Number(code) => Some(*code as i32),
        _ => None,
    }
}

/// Returns the table `require` caches modules in, keyed by module name.
///
/// # Errors
///
/// Returns the Lua error when the registry slot is missing.
pub fn loaded(lua: &Lua) -> mlua::Result<Table> {
    lua.named_registry_value(LOADED_KEY)
}

/// Makes `table` the module `require(name)` returns ahead of any file.
///
/// # Errors
///
/// Returns the Lua error when the registry slot is missing.
pub fn add_native(lua: &Lua, name: &str, table: Table) -> mlua::Result<()> {
    let natives: Table = lua.named_registry_value(NATIVES_KEY)?;
    natives.raw_set(name, table)
}

/// Returns the folder of the Luau file that called `require`, or the working folder when the
/// caller is a chunk with no file.
fn caller_folder(lua: &Lua) -> PathBuf {
    for level in 1.. {
        let source = lua.inspect_stack(level, |debug| {
            debug.source().source.map(std::borrow::Cow::into_owned)
        });
        match source {
            None => break,
            Some(Some(source)) if source.starts_with('@') => {
                let path = Path::new(&source[1..]);
                let folder = match path.parent() {
                    Some(parent) if !parent.as_os_str().is_empty() => parent,
                    _ => Path::new("."),
                };
                return std::path::absolute(folder).unwrap_or_else(|_| folder.to_path_buf());
            }
            Some(Some(source)) if source != "=[C]" => break,
            Some(_) => {}
        }
    }
    std::env::current_dir().unwrap_or_default()
}

/// Loads module `name` for a chunk with no file, so `./` paths start at the working folder.
///
/// # Errors
///
/// Returns the errors of [`require_from`].
pub fn require(lua: &Lua, name: &str) -> mlua::Result<Value> {
    require_from(lua, name, &std::env::current_dir().unwrap_or_default())
}

/// Loads module `name` once and returns what its chunk returned, as Lua's `require` does.
///
/// `@dev/X` is a native module, else `luau/dev/X.luau` or `luau/dev/X/init.luau` of the embedded
/// tree. Any other name is a path or `.luaurc` alias that [`resolve`] reads against `origin`,
/// loaded from `.luau` or `init.luau`.
///
/// # Errors
///
/// Returns the sentence of [`resolve`] for a name that is not a Luau path, an error naming
/// every place tried when no module is found, and the chunk's own error when loading it fails.
pub fn require_from(lua: &Lua, name: &str, origin: &Path) -> mlua::Result<Value> {
    let target = resolve(name, origin).map_err(|error| Error::runtime(error.to_string()))?;
    let loaded = loaded(lua)?;
    if let Target::Dev(rest) = &target {
        let key = format!("{DEV_ALIAS}{rest}");
        let cached: Value = loaded.raw_get(key.as_str())?;
        if !cached.is_nil() {
            return Ok(cached);
        }
        let natives: Table = lua.named_registry_value(NATIVES_KEY)?;
        let native: Value = natives.raw_get(key.as_str())?;
        if !native.is_nil() {
            loaded.raw_set(key.as_str(), &native)?;
            return Ok(native);
        }
    }
    let (source, chunkname, key) = find(name, &target)?;
    let cached: Value = loaded.raw_get(key.as_str())?;
    if !cached.is_nil() {
        return Ok(cached);
    }

    // Run the module's chunk, refusing a module that requires itself while it loads
    if !with_state(lua, |state| state.loading.insert(key.clone()))? {
        return Err(Error::runtime(format!(
            "loop or previous error loading module '{name}'"
        )));
    }
    let result =
        load(lua, &source, &chunkname, None).and_then(|chunk| chunk.call::<Value>(key.as_str()));
    with_state(lua, |state| state.loading.remove(&key))?;
    let value = match result? {
        Value::Nil => match loaded.raw_get::<Value>(key.as_str())? {
            Value::Nil => Value::Boolean(true),
            set => set,
        },
        value => value,
    };
    if let Value::Table(module) = &value
        && log::module_calls()
    {
        trace_module_calls(lua, &trace_name(&key), module)?;
    }
    loaded.raw_set(key.as_str(), &value)?;
    Ok(value)
}

/// Returns `dev.X.Y` for the key `@dev/X/Y`, and the file's name without `.luau` for a file, or
/// its folder's name for an `init.luau`.
fn trace_name(key: &str) -> String {
    if let Some(rest) = key.strip_prefix(DEV_ALIAS) {
        return format!("dev.{}", rest.replace('/', "."));
    }
    let path = Path::new(key);
    let module = match path.file_stem().and_then(|stem| stem.to_str()) {
        Some("init") => path.parent().and_then(Path::file_name),
        _ => path.file_stem(),
    };
    module.map_or_else(
        || key.to_owned(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// Wraps every function field of module table `module` so each call is traced as `NAME.FIELD`.
///
/// The wrapper is Luau, so a wrapped function still yields and returns every value.
fn trace_module_calls(lua: &Lua, name: &str, module: &Table) -> mlua::Result<()> {
    let wrap = match lua.named_registry_value::<Option<Function>>(MODULE_CALL_WRAP_KEY)? {
        Some(wrap) => wrap,
        None => {
            let trace = lua.create_function(|_, called: LuaString| {
                log::module_call(&called.to_string_lossy());
                Ok(())
            })?;
            let wrap: Function =
                load(lua, MODULE_CALL_WRAPPER.as_bytes(), "=dev.trace", None)?.call(trace)?;
            lua.set_named_registry_value(MODULE_CALL_WRAP_KEY, &wrap)?;
            wrap
        }
    };
    let mut functions = Vec::new();
    for pair in module.pairs::<Value, Value>() {
        if let (Value::String(key), Value::Function(function)) = pair? {
            functions.push((key.to_string_lossy(), function));
        }
    }
    for (key, function) in functions {
        let wrapped: Function = wrap.call((format!("{name}.{key}"), function))?;
        module.raw_set(key, wrapped)?;
    }
    Ok(())
}

/// Finds the source of the module `target` names, the chunk name it loads under and its cache key.
fn find(name: &str, target: &Target) -> mlua::Result<(Vec<u8>, String, String)> {
    let mut tried = Vec::new();
    match target {
        Target::Dev(rest) => {
            for candidate in [
                format!("{EMBEDDED_MODULES}/{rest}.luau"),
                format!("{EMBEDDED_MODULES}/{rest}/init.luau"),
            ] {
                if let Some(bytes) = embed::file(&candidate) {
                    return Ok((
                        bytes.to_vec(),
                        format!("@{candidate}"),
                        format!("{DEV_ALIAS}{rest}"),
                    ));
                }
                tried.push(format!("no embedded file '{candidate}'"));
            }
        }
        Target::Disk(base) => {
            let mut stem = base.clone().into_os_string();
            stem.push(".luau");
            for candidate in [PathBuf::from(stem), base.join("init.luau")] {
                if let Ok(bytes) = fs::read(&candidate) {
                    let key = candidate
                        .canonicalize()
                        .unwrap_or_else(|_| candidate.clone());
                    return Ok((
                        bytes,
                        format!("@{}", candidate.display()),
                        key.display().to_string(),
                    ));
                }
                tried.push(format!("no file '{}'", candidate.display()));
            }
        }
    }
    Err(Error::runtime(format!(
        "module '{name}' not found:\n\t{}",
        tried.join("\n\t")
    )))
}

/// Compiles `source` into a function named `chunkname`, run in `env` when one is given.
///
/// # Errors
///
/// Returns the syntax error when `source` does not compile.
pub fn load(
    lua: &Lua,
    source: &[u8],
    chunkname: &str,
    env: Option<Table>,
) -> mlua::Result<Function> {
    let chunk = lua.load(source).set_name(chunkname);
    match env {
        Some(env) => chunk.set_environment(env).into_function(),
        None => chunk.into_function(),
    }
}

/// Runs the Luau file at `path` and returns its values, as Lua's `dofile` does.
///
/// # Errors
///
/// Returns an error when the file cannot be read or compiled, and the chunk's own error.
pub fn dofile(lua: &Lua, path: &str) -> mlua::Result<MultiValue> {
    let source = fs::read(path).map_err(|source| DevError::io(format!("read {path}"), source))?;
    load(lua, &source, &format!("@{path}"), None)?.call(())
}

/// Registers `cleanup` to run when dev exits, however it ends.
///
/// # Errors
///
/// Returns the Lua error when the cleanup list is missing.
pub fn on_exit(lua: &Lua, cleanup: Function) -> mlua::Result<()> {
    let cleanups: Table = lua.named_registry_value(CLEANUPS_KEY)?;
    cleanups.raw_push(cleanup)
}

/// Runs every registered cleanup once, newest first.
///
/// A cleanup that fails is reported on standard error and the rest still run.
pub fn run_cleanups(lua: &Lua) {
    let Ok(cleanups) = lua.named_registry_value::<Table>(CLEANUPS_KEY) else {
        return;
    };
    while let Ok(Some(cleanup)) = cleanups.raw_pop::<Option<Function>>() {
        if let Err(error) = cleanup.call::<()>(()) {
            write_err(format!("A cleanup failed: {}.\n", message(&error)).as_bytes());
        }
    }
}

/// Runs the cleanups, flushes both output streams and ends the process with `code`.
///
/// A closed standard output ends with [`BROKEN_PIPE_EXIT`], and any other failed flush is
/// reported and turns a success into [`FAILURE_EXIT`].
pub fn exit(lua: &Lua, code: i32) -> ! {
    run_cleanups(lua);
    let code = match flush_out(lua) {
        Ok(()) => code,
        Err(error) => {
            write_err(format!("dev: Failed to write the output: {}\n", message(&error)).as_bytes());
            if code == 0 { FAILURE_EXIT } else { code }
        }
    };

    // Standard error has nowhere left to report its own failure
    let _ = io::stderr().lock().flush();
    process::exit(code)
}

/// Writes `bytes` to the buffered standard output that `print` and `dev.os.stdout` share.
///
/// A closed pipe ends dev with [`BROKEN_PIPE_EXIT`] and no message, after the cleanups.
///
/// # Errors
///
/// Returns any other write failure.
pub fn write_out(lua: &Lua, bytes: &[u8]) -> mlua::Result<()> {
    if PIPE_CLOSED.load(Ordering::SeqCst) {
        return Ok(());
    }
    let result = io::stdout().lock().write_all(bytes);
    closed_pipe_exits(lua, result)
}

/// Flushes the shared standard output, with the closed-pipe handling of [`write_out`].
///
/// # Errors
///
/// Returns any failure other than a closed pipe.
pub fn flush_out(lua: &Lua) -> mlua::Result<()> {
    if PIPE_CLOSED.load(Ordering::SeqCst) {
        return Ok(());
    }
    let result = io::stdout().lock().flush();
    closed_pipe_exits(lua, result)
}

/// Ends dev quietly when `result` failed on a closed pipe and passes any other result on.
fn closed_pipe_exits(lua: &Lua, result: io::Result<()>) -> mlua::Result<()> {
    match result {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::BrokenPipe => {
            PIPE_CLOSED.store(true, Ordering::SeqCst);
            exit(lua, BROKEN_PIPE_EXIT)
        }
        Err(error) => Err(Error::external(error)),
    }
}

/// Writes `bytes` to standard error, dropping them when it is closed.
pub fn write_err(bytes: &[u8]) {
    let _ = io::stderr().lock().write_all(bytes);
}

/// Writes `print`'s values to the shared standard output, tab-separated with a final newline.
fn print(lua: &Lua, tostring: &Function, values: MultiValue) -> mlua::Result<()> {
    let mut line = Vec::new();
    for (index, value) in values.into_iter().enumerate() {
        if index > 0 {
            line.push(b'\t');
        }
        let text: LuaString = tostring.call(value)?;
        line.extend_from_slice(&text.as_bytes());
    }
    line.push(b'\n');
    write_out(lua, &line)
}

/// Returns the message of `error` without mlua's wording or a traceback.
#[must_use]
pub fn message(error: &Error) -> String {
    match error {
        Error::RuntimeError(text) => text
            .split("\nstack traceback:")
            .next()
            .unwrap_or(text)
            .to_owned(),
        Error::SyntaxError { message, .. } => message.clone(),
        Error::CallbackError { cause, .. } => message(cause),
        Error::WithContext { context, cause } => format!("{context}: {}", message(cause)),
        other => other.to_string(),
    }
}

/// Returns the Luau traceback `error` carries, when it has one.
#[must_use]
pub fn traceback(error: &Error) -> Option<String> {
    match error {
        Error::RuntimeError(text) => text
            .find("stack traceback:")
            .map(|at| text[at..].to_owned()),
        Error::CallbackError { traceback, .. } => Some(traceback.clone()),
        Error::WithContext { cause, .. } => traceback(cause),
        _ => None,
    }
}

/// Writes `error` to standard error as `dev: MESSAGE` and its traceback.
pub fn report(error: &Error) {
    let mut text = format!("dev: {}\n", message(error));
    if let Some(traceback) = traceback(error) {
        text.push_str(&traceback);
        if !traceback.ends_with('\n') {
            text.push('\n');
        }
    }
    write_err(text.as_bytes());
}

/// Returns whether dev runs with an effective user id of 0, which is never so on Windows.
#[must_use]
pub fn is_root() -> bool {
    #[cfg(unix)]
    {
        rustix::process::geteuid().is_root()
    }
    #[cfg(windows)]
    {
        false
    }
}

/// Runs `f` on the module search state.
fn with_state<R>(lua: &Lua, f: impl FnOnce(&mut SearchState) -> R) -> mlua::Result<R> {
    let mut state = lua
        .app_data_mut::<SearchState>()
        .ok_or_else(|| Error::runtime("the module search state is missing"))?;
    Ok(f(&mut state))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn interrupt_should_stop_a_running_loop_with_the_signal_status() {
        let lua = new().unwrap();
        let spin = lua.load("while true do end").into_function().unwrap();
        interrupt(signal_hook::consts::SIGTERM);
        let error = spin.call::<()>(()).unwrap_err();
        assert!(is_interrupt(&error), "{error}");
        assert_eq!(
            interrupt_code(),
            SIGNAL_EXIT_BASE + signal_hook::consts::SIGTERM
        );

        // A real signal through the slot signal-hook writes interrupts the same way
        let hup = signal_hook::consts::SIGHUP;
        let slot = usize::try_from(hup).unwrap();
        signal_hook::flag::register_usize(hup, interrupt_slot(), slot).unwrap();
        signal_hook::low_level::raise(hup).unwrap();
        assert!(interrupted());
        let error = spin.call::<()>(()).unwrap_err();
        assert!(is_interrupt(&error), "{error}");
        assert!(!interrupted());
        assert_eq!(interrupt_code(), SIGNAL_EXIT_BASE + hup);
        assert!(check_interrupt().is_ok());

        // A signal the handler stored names the status before Luau raises it
        let term = signal_hook::consts::SIGTERM;
        interrupt_slot().store(usize::try_from(term).unwrap(), Ordering::SeqCst);
        assert_eq!(interrupt_code(), SIGNAL_EXIT_BASE + term);
        assert!(check_interrupt().is_err());
        assert_eq!(interrupt_code(), SIGNAL_EXIT_BASE + term);
    }

    #[test]
    fn is_interrupt_should_refuse_an_error_that_only_quotes_the_text() {
        let lua = Lua::new();
        let error = lua
            .load(r#"error("rebase interrupted! by hand", 0)"#)
            .exec()
            .unwrap_err();
        assert!(!is_interrupt(&error));
    }

    #[test]
    fn exit_status_should_read_numbers_and_ignore_other_values() {
        assert_eq!(exit_status(&Value::Integer(3)), Some(3));
        assert_eq!(exit_status(&Value::Number(4.7)), Some(4));
        assert_eq!(exit_status(&Value::Integer(i64::MAX)), Some(FAILURE_EXIT));
        assert_eq!(exit_status(&Value::Nil), None);
        assert_eq!(exit_status(&Value::Boolean(true)), None);
    }
}

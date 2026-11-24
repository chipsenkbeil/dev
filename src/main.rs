#![forbid(unsafe_code)]

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::{env, fs, process};

use dev::flags::{self, Flags, FlagsEnv, FlagsScript};
use dev::runtime::{self, FAILURE_EXIT};
use dev::{modules, native};
use mlua::{Error, ErrorContext, Function, Lua, Table, Value, Variadic};

/// Exit status of a usage error.
const USAGE_EXIT: i32 = 2;

/// Module whose `main` runs a dev command line.
const CLI_MODULE: &str = "dev.cli";

/// Module that holds the parsed global flags.
const GLOBALS_MODULE: &str = "dev.globals";

/// Module whose loading marks a file as a suite of registered cases.
const TESTING_MODULE: &str = "dev.testing";

/// Module whose `finish` runs the registered cases.
const TESTRUN_MODULE: &str = "dev.testrun";

/// Runs dev's command line and exits with its status.
fn main() {
    native::os::install_signals();
    let Some(args) = utf8_args(env::args_os().skip(1)) else {
        usage(&"An argument to dev is not valid UTF-8.");
    };
    let flags =
        flags::load(args, &FlagsEnv::from_environment()).unwrap_or_else(|error| usage(&error));
    let lua = match start(&flags) {
        Ok(lua) => lua,
        Err(error) => {
            runtime::report(&error);
            process::exit(FAILURE_EXIT);
        }
    };
    let code = match &flags.script {
        Some(script) => run_file(&lua, script),
        None => run_cli(&lua),
    };
    runtime::exit(&lua, code)
}

/// Writes the usage error `sentence` and ends dev with [`USAGE_EXIT`].
fn usage(sentence: &dyn std::fmt::Display) -> ! {
    runtime::write_err(format!("{sentence}\n").as_bytes());
    process::exit(USAGE_EXIT)
}

/// Returns the arguments as strings, or `None` when one is not valid UTF-8.
fn utf8_args(args: impl Iterator<Item = OsString>) -> Option<Vec<String>> {
    args.map(OsString::into_string)
        .collect::<Result<_, _>>()
        .ok()
}

/// Creates the Lua state and registers every native module in it.
fn start(flags: &Flags) -> mlua::Result<Lua> {
    let lua = runtime::new().context("Failed to create the Luau state")?;
    modules::register(&lua, flags).context("Failed to register the native modules")?;
    Ok(lua)
}

/// Runs the Luau file `-l` names with its words in the global `arg`, and returns the exit status.
fn run_file(lua: &Lua, script: &FlagsScript) -> i32 {
    if !Path::new(&script.path).is_file() {
        runtime::write_err(format!("The file {} does not exist.\n", script.path).as_bytes());
        return USAGE_EXIT;
    }
    finish(lua, file_chunk(lua, &script.path, &script.args))
}

/// Loads the file at `path` with `args` in the global `arg`, runs it and returns what it returned.
///
/// The path gets the file's folder first, then the `.dev/lib` of the project that holds the file.
fn file_chunk(lua: &Lua, path: &str, args: &[String]) -> mlua::Result<Value> {
    let folder = Path::new(path)
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    if let Some(lib) = project_lib(folder) {
        runtime::add_path(lua, lib)?;
    }
    runtime::add_path(lua, folder)?;
    let arg = lua.create_sequence_from(args.iter().map(String::as_str))?;
    arg.raw_set(0, path)?;
    lua.globals()
        .set("arg", arg)
        .context("Failed to set the global `arg`")?;
    let source = fs::read(path).map_err(|source| dev::Error::io(format!("read {path}"), source))?;
    let chunk = runtime::load(lua, &source, &format!("@{path}"), None)?;
    let value = chunk.call::<Value>(Variadic::from(args.to_vec()))?;
    run_registered_cases(lua, value)
}

/// Runs the `dev.testing` cases the file registered, and returns the status to exit with.
///
/// The file's own return value stays when it asks for a failure or when no case ran.
fn run_registered_cases(lua: &Lua, value: Value) -> mlua::Result<Value> {
    if runtime::loaded(lua)?
        .raw_get::<Value>(TESTING_MODULE)?
        .is_nil()
    {
        return Ok(value);
    }
    let testrun: Table = runtime::require(lua, TESTRUN_MODULE)?
        .as_table()
        .cloned()
        .ok_or_else(|| {
            Error::runtime(format!(
                "the module '{TESTRUN_MODULE}' did not return a table"
            ))
        })?;
    let finish: Function = testrun
        .get("finish")
        .context("Failed to read `finish` of dev.testrun")?;
    let cases: Value = finish.call(())?;
    let failed = matches!(runtime::exit_status(&value), Some(code) if code != 0);
    Ok(if failed || cases.is_nil() {
        value
    } else {
        cases
    })
}

/// Returns the `.dev/lib` folder of the nearest project at or above `folder`, if it has one.
fn project_lib(folder: &Path) -> Option<PathBuf> {
    let start = folder.canonicalize().ok()?;
    start
        .ancestors()
        .map(|dir| dir.join(".dev").join("lib"))
        .find(|lib| lib.is_dir())
}

/// Runs `dev.cli`'s `main` on `dev.globals` and returns its exit status.
fn run_cli(lua: &Lua) -> i32 {
    finish(lua, cli_main(lua))
}

/// Calls `require("dev.cli").main(require("dev.globals"))`.
fn cli_main(lua: &Lua) -> mlua::Result<Value> {
    let globals = runtime::require(lua, GLOBALS_MODULE)?;
    let cli: Table = runtime::require(lua, CLI_MODULE)?
        .as_table()
        .cloned()
        .ok_or_else(|| {
            Error::runtime(format!("the module '{CLI_MODULE}' did not return a table"))
        })?;
    let main: Function = cli
        .get("main")
        .context("Failed to read `main` of dev.cli")?;
    main.call(globals)
}

/// Turns a run's result into an exit status, reporting an error that escaped.
fn finish(lua: &Lua, result: mlua::Result<Value>) -> i32 {
    match result {
        Ok(value) => runtime::exit_status(&value).unwrap_or(0),
        Err(error) if runtime::is_interrupt(&error) => runtime::interrupt_code(),
        Err(error) => {
            // Output printed before the error belongs above its report
            let _ = runtime::flush_out(lua);
            runtime::report(&error);
            FAILURE_EXIT
        }
    }
}

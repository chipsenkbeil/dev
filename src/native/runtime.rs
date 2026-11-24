use std::env;
use std::result::Result as StdResult;

use mlua::{Function, Lua, LuaString, MultiValue, Table, Value};

use crate::flags::{self, FlagsEnv};
use crate::luau::{self, LuauFnRecord};
use crate::native::{globals, os};
use crate::runtime::{self, EXEC_FAILED, FAILURE_EXIT, SIGNAL_EXIT_BASE};
use crate::{embed, native_fn, native_struct};

/// Name of this module under `dev`.
pub const NAME: &str = "runtime";

/// Chunk name a `load` without one gets, as Lua's `load` gives.
const DEFAULT_CHUNKNAME: &str = "=(load)";

/// Version of this dev, from the crate version.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

native_struct! {
    /// Signature of one native function, as the type files will be written from.
    pub struct RuntimeSignature {
        /// Module name under `dev`, such as `os`.
        pub module: String,
        /// Function name inside the module.
        pub name: String,
        /// Luau function type.
        pub signature: String,
        /// Doc comment lines.
        pub docs: Vec<String>,
    }
}

impl From<LuauFnRecord> for RuntimeSignature {
    fn from(record: LuauFnRecord) -> Self {
        Self {
            module: record.module.to_owned(),
            name: record.name.to_owned(),
            signature: record.signature(),
            docs: record.docs.iter().map(|line| (*line).to_owned()).collect(),
        }
    }
}

native_fn! {
    /// Compiles `source` into a function, or returns `nil` and the syntax error.
    ///
    /// The function runs in `env` when one is given, and in the globals otherwise.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the source string cannot be read.
    pub fn load(
        lua: &Lua,
        source: LuaString,
        chunkname: Option<String>,
        env: Option<Table>,
    ) -> mlua::Result<StdResult<Function, String>> {
        let chunkname = chunkname.unwrap_or_else(|| DEFAULT_CHUNKNAME.to_owned());
        let chunk = runtime::load(lua, &source.as_bytes(), &chunkname, env);
        Ok(chunk.map_err(|error| runtime::message(&error)))
    }
}

native_fn! {
    /// Runs the Luau file at `path` and returns its values, raising any error.
    ///
    /// # Errors
    ///
    /// Returns the read, syntax or runtime error of the file.
    pub fn dofile(lua: &Lua, path: String) -> mlua::Result<MultiValue> {
        runtime::dofile(lua, &path)
    }
}

native_fn! {
    /// Returns the embedded file at `path`, such as `docs/flags.md`, or `nil`.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the string cannot be created.
    pub fn asset(lua: &Lua, path: String) -> mlua::Result<Option<LuaString>> {
        embed::file(&path).map(|bytes| lua.create_string(bytes)).transpose()
    }
}

native_fn! {
    /// Returns the sorted names of the files and folders inside the embedded folder at `path`.
    ///
    /// A path that names no embedded folder gives an empty list.
    ///
    /// # Errors
    ///
    /// Never fails; the result type is the one every native function shares.
    pub fn assets(_lua: &Lua, path: String) -> mlua::Result<Vec<String>> {
        Ok(embed::entries(&path).unwrap_or_default())
    }
}

native_fn! {
    /// Returns the signature of every native function registered so far.
    ///
    /// # Errors
    ///
    /// Never fails; the result type is the one every native function shares.
    pub fn signatures(_lua: &Lua) -> mlua::Result<Vec<RuntimeSignature>> {
        Ok(luau::records().into_iter().map(RuntimeSignature::from).collect())
    }
}

native_fn! {
    /// Runs the cleanups, flushes the output and ends dev with `code`.
    ///
    /// `true` or no code exits 0 and `false` exits 1, as Lua's `os.exit` does.
    ///
    /// # Errors
    ///
    /// Returns a bad-argument error when `code` is neither a number nor a boolean.
    #[luau = "(code: (number | boolean)?) -> never"]
    pub fn exit(lua: &Lua, code: Option<Value>) -> mlua::Result<()> {
        let code = match code.unwrap_or(Value::Nil) {
            Value::Nil | Value::Boolean(true) => 0,
            Value::Boolean(false) => FAILURE_EXIT,
            other => runtime::exit_status(&other).ok_or_else(|| {
                mlua::Error::runtime(format!(
                    "bad argument #1 to 'exit' (number or boolean expected, got {})",
                    other.type_name(),
                ))
            })?,
        };
        runtime::exit(lua, code)
    }
}

native_fn! {
    /// Registers `cleanup` to run once when dev exits, however it ends.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the cleanup list cannot be read.
    pub fn on_exit(lua: &Lua, cleanup: Function) -> mlua::Result<()> {
        runtime::on_exit(lua, cleanup)
    }
}

native_fn! {
    /// Runs every registered cleanup once, newest first.
    ///
    /// # Errors
    ///
    /// Never fails; a failed cleanup is reported and the rest still run.
    pub fn run_cleanups(lua: &Lua) -> mlua::Result<()> {
        runtime::run_cleanups(lua);
        Ok(())
    }
}

native_fn! {
    /// Returns the exit status for an interrupt: 128 plus the signal that caused it.
    ///
    /// # Errors
    ///
    /// Never fails; the result type is the one every native function shares.
    pub fn interrupt_code(_lua: &Lua) -> mlua::Result<i32> {
        Ok(runtime::interrupt_code())
    }
}

native_fn! {
    /// Parses `words` as the command line after the program name, the way the binary does.
    ///
    /// It also does what the binary does with the flags: enters each `-C` folder, exports
    /// `--agent` and applies the verbosity. Returns a table shaped like `dev.globals`, or `nil` and
    /// the usage message for a flag that is wrong.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the table cannot be built.
    #[luau = "(words: { string }) -> ({ [string]: any }?, string?)"]
    pub fn parse_globals(lua: &Lua, words: Vec<String>) -> mlua::Result<StdResult<Table, String>> {
        match flags::load(words, &FlagsEnv::from_environment()) {
            Ok(flags) => globals::register(lua, &flags).map(Ok),
            Err(error) => Ok(Err(error.to_string())),
        }
    }
}

/// Creates the `dev.runtime` module table.
///
/// # Errors
///
/// Returns the Lua error when a function or field cannot be set.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    load::register(lua, NAME, &table)?;
    dofile::register(lua, NAME, &table)?;

    asset::register(lua, NAME, &table)?;
    assets::register(lua, NAME, &table)?;
    signatures::register(lua, NAME, &table)?;
    parse_globals::register(lua, NAME, &table)?;
    table.set("exe", exe())?;
    table.set("version", VERSION)?;
    table.set("loaded", runtime::loaded(lua)?)?;
    Ok(table)
}

/// Adds the exit functions and exit statuses the core owns to the `dev.os` table `os_table`.
///
/// # Errors
///
/// Returns the Lua error when a function or field cannot be set.
pub fn register_exit(lua: &Lua, os_table: &Table) -> mlua::Result<()> {
    exit::register(lua, os::NAME, os_table)?;
    on_exit::register(lua, os::NAME, os_table)?;
    run_cleanups::register(lua, os::NAME, os_table)?;
    interrupt_code::register(lua, os::NAME, os_table)?;
    os_table.set("SIGNAL_EXIT_BASE", SIGNAL_EXIT_BASE)?;
    os_table.set("EXEC_FAILED", EXEC_FAILED)
}

/// Returns the canonical path of the running binary, or an empty string when it is unknown.
#[must_use]
fn exe() -> String {
    env::current_exe()
        .and_then(|path| path.canonicalize())
        .map(|path| path.display().to_string())
        .unwrap_or_default()
}

use mlua::{Lua, Table};

use crate::log::{self, LogLevel};
use crate::native_fn;

/// Name of this module under `dev`.
pub const NAME: &str = "log";

native_fn! {
    /// Writes `message` to stderr as an error, which shows even under `-q`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn error(_lua: &Lua, message: String) -> mlua::Result<()> {
        log::write(LogLevel::Error, &message);
        Ok(())
    }
}

native_fn! {
    /// Writes `message` to stderr as a warning, hidden under `-q`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn warn(_lua: &Lua, message: String) -> mlua::Result<()> {
        log::write(LogLevel::Warn, &message);
        Ok(())
    }
}

native_fn! {
    /// Writes `message` to stderr unless `-q` was given.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn info(_lua: &Lua, message: String) -> mlua::Result<()> {
        log::write(LogLevel::Info, &message);
        Ok(())
    }
}

native_fn! {
    /// Writes `message` to stderr from `-v`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn debug(_lua: &Lua, message: String) -> mlua::Result<()> {
        log::write(LogLevel::Debug, &message);
        Ok(())
    }
}

native_fn! {
    /// Writes `message` to stderr from `-vv`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn trace(_lua: &Lua, message: String) -> mlua::Result<()> {
        log::write(LogLevel::Trace, &message);
        Ok(())
    }
}

native_fn! {
    /// Returns whether a line of `level` is shown at the current verbosity.
    ///
    /// # Errors
    ///
    /// Raises when `level` is not a level name.
    pub fn enabled(_lua: &Lua, level: LogLevel) -> mlua::Result<bool> {
        Ok(log::enabled(level))
    }
}

native_fn! {
    /// Returns the verbosity, from 0 to 4, and whether only errors show, which `-q` asks for.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn verbosity(_lua: &Lua) -> mlua::Result<(u8, bool)> {
        Ok((log::verbosity(), log::threshold() == LogLevel::Error))
    }
}

native_fn! {
    /// Gives the `dev.globals.stripped` words at `indexes` back to the command and returns the
    /// verbosity and quiet the rest ask for, which take effect at once.
    ///
    /// # Errors
    ///
    /// Raises when `indexes` is not a list of numbers.
    pub fn retake(_lua: &Lua, indexes: Vec<usize>) -> mlua::Result<(u8, bool)> {
        Ok(log::retake(&indexes))
    }
}

native_fn! {
    /// Returns whether a `.sh` command should run under `bash -x`, from `-vvv`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    pub fn xtrace(_lua: &Lua) -> mlua::Result<bool> {
        Ok(log::xtrace())
    }
}

/// Creates the `dev.log` module table.
///
/// # Errors
///
/// Returns the Lua error when a function cannot be set.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    error::register(lua, NAME, &table)?;
    warn::register(lua, NAME, &table)?;
    info::register(lua, NAME, &table)?;
    debug::register(lua, NAME, &table)?;
    trace::register(lua, NAME, &table)?;
    enabled::register(lua, NAME, &table)?;
    verbosity::register(lua, NAME, &table)?;
    retake::register(lua, NAME, &table)?;
    xtrace::register(lua, NAME, &table)?;
    Ok(table)
}

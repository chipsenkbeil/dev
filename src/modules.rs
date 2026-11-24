use mlua::{Lua, Table};

use crate::flags::Flags;
use crate::native::{
    fs, globals, hash, http, json, lock, log, manifest, os, runtime, spec, term, toml,
};
use crate::resolve::DEV_ALIAS;
use crate::runtime::add_native;

/// Registers every native module under `dev.*`, in the order later modules may rely on.
///
/// `flags` fills `dev.globals`.
///
/// # Errors
///
/// Returns the Lua error of the first module that fails to register.
pub fn register(lua: &Lua, flags: &Flags) -> mlua::Result<()> {
    add(lua, runtime::NAME, runtime::register(lua)?)?;
    add(lua, globals::NAME, globals::register(lua, flags)?)?;
    add(lua, log::NAME, log::register(lua)?)?;
    let os_table = os::register(lua)?;
    runtime::register_exit(lua, &os_table)?;
    add(lua, os::NAME, os_table)?;
    add(lua, fs::NAME, fs::register(lua)?)?;
    add(lua, lock::NAME, lock::register(lua)?)?;
    add(lua, hash::NAME, hash::register(lua)?)?;
    add(lua, http::NAME, http::register(lua)?)?;
    add(lua, json::NAME, json::register(lua)?)?;
    add(lua, toml::NAME, toml::register(lua)?)?;
    add(lua, manifest::NAME, manifest::register(lua)?)?;
    add(lua, term::NAME, term::register(lua)?)?;
    add(lua, spec::NAME, spec::register(lua)?)
}

/// Makes `table` the module `require("@dev/NAME")` returns.
fn add(lua: &Lua, name: &str, table: Table) -> mlua::Result<()> {
    add_native(lua, &format!("{DEV_ALIAS}{name}"), table)
}

use mlua::{Lua, Table};

use crate::flags::Flags;

/// Name of this module under `dev`.
pub const NAME: &str = "globals";

/// Creates the `dev.globals` table from the parsed global flags.
///
/// Its fields are `args`, `after`, `dashed`, `remote`, `detach`, `priority`, `job_timeout`,
/// `local_flag`, `env_local`, `conflict`, `level`, `quiet`, `agent` and `stripped`, as [`Flags`]
/// documents them. Each `stripped` entry is a `{ at, word }` table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be built.
pub fn register(lua: &Lua, flags: &Flags) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set(
        "args",
        lua.create_sequence_from(flags.args.iter().map(String::as_str))?,
    )?;
    table.set("after", flags.after)?;
    table.set("dashed", flags.dashed)?;
    table.set("remote", flags.remote)?;
    table.set("detach", flags.detach)?;
    table.set("priority", flags.priority)?;
    table.set("job_timeout", flags.job_timeout.as_deref())?;
    table.set("local_flag", flags.local_flag)?;
    table.set("env_local", flags.env_local)?;
    table.set("conflict", flags.conflict)?;
    table.set("level", flags.level)?;
    table.set("quiet", flags.quiet)?;
    table.set("agent", flags.agent.as_deref())?;
    let stripped = lua.create_table()?;
    for entry in &flags.stripped {
        let row = lua.create_table()?;
        row.set("at", entry.at)?;
        row.set("word", entry.word.as_str())?;
        stripped.push(row)?;
    }
    table.set("stripped", stripped)?;
    Ok(table)
}

use mlua::{Lua, Table};

use crate::flags::Flags;
use crate::luau;

/// Name of this module under `dev`.
pub const NAME: &str = "globals";

/// Records the type and doc line of one field of the table.
fn field(name: &'static str, luau_type: &str, doc: &'static str) {
    luau::value(NAME, name, luau_type.to_owned(), doc);
}

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
    field(
        "args",
        "{ string }",
        "The command words and their arguments, without the first `--` and the verbosity words.",
    );
    table.set("after", flags.after)?;
    field(
        "after",
        "number",
        "Number of words after the first `--`, 0 when none was typed.",
    );
    table.set("dashed", flags.dashed)?;
    field(
        "dashed",
        "boolean",
        "Whether a `--` was typed, even with nothing after it.",
    );
    table.set("remote", flags.remote)?;
    field(
        "remote",
        "boolean",
        "Whether `--remote` or `DEV_REMOTE` asks for a remote run, and `--local` does not.",
    );
    table.set("detach", flags.detach)?;
    field("detach", "boolean", "Whether `--detach` was given.");
    table.set("priority", flags.priority)?;
    field("priority", "boolean", "Whether `--priority` was given.");
    table.set("job_timeout", flags.job_timeout.as_deref())?;
    field(
        "job_timeout",
        "string?",
        "The `--job-timeout` value, empty when the flag had none, `nil` when it was not given.",
    );
    table.set("local_flag", flags.local_flag)?;
    field("local_flag", "boolean", "Whether `--local` was given.");
    table.set("env_local", flags.env_local)?;
    field(
        "env_local",
        "boolean",
        "Whether `DEV_REMOTE` says 0, no or false.",
    );
    table.set("conflict", flags.conflict)?;
    field(
        "conflict",
        "boolean",
        "Whether `--local` and `--remote` were both given.",
    );
    table.set("level", flags.level)?;
    field(
        "level",
        "number",
        "Verbosity, from 0 to the highest the log allows.",
    );
    table.set("quiet", flags.quiet)?;
    field("quiet", "boolean", "Whether `-q` or `--quiet` was given.");
    table.set("agent", flags.agent.as_deref())?;
    field(
        "agent",
        "string?",
        "Name `--agent` gives, `nil` when it was not given.",
    );
    let stripped = lua.create_table()?;
    for entry in &flags.stripped {
        let row = lua.create_table()?;
        row.set("at", entry.at)?;
        row.set("word", entry.word.as_str())?;
        stripped.push(row)?;
    }
    table.set("stripped", stripped)?;
    field(
        "stripped",
        "{ { at: number, word: string } }",
        "Verbosity words taken from after the first command word, with where each one stood.",
    );
    Ok(table)
}

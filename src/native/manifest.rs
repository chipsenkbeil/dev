use std::collections::HashMap;
use std::result::Result as StdResult;

use mlua::{Lua, LuaString, Table};

use super::json::OnLua;
use crate::{Error, native_fn, native_struct, overlay};

/// Name of this module under `dev`.
pub const NAME: &str = "manifest";

/// The 1-based index of the first package manager column.
const FIRST_MANAGER_FIELD: usize = 3;

/// The header of the column that lists the groups of a row.
const GROUPS_COLUMN: &str = "groups";

/// Creates the `dev.manifest` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be built.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    parse::register(lua, NAME, &table)?;
    column::register(lua, NAME, &table)?;
    select::register(lua, NAME, &table)?;
    Ok(table)
}

/// Tells whether `char` is whitespace to Lua's `%s`.
pub(super) fn is_space(char: char) -> bool {
    matches!(char, ' ' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r')
}

/// Splits a line into cells on runs of spaces and tabs, where a double-quoted run is one cell.
fn tokenize(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    for char in line.chars() {
        if quoted {
            if char == '"' {
                quoted = false;
            } else {
                current.push(char);
            }
        } else if char == '"' {
            quoted = true;
            started = true;
        } else if char == ' ' || char == '\t' {
            if started {
                fields.push(std::mem::take(&mut current));
                started = false;
            }
        } else {
            current.push(char);
            started = true;
        }
    }
    if started {
        fields.push(current);
    }
    fields
}

/// Returns the text of a `# @env` line after its marker, or `None` when the line is not one.
fn env_rest(line: &str) -> Option<&str> {
    let rest = line.trim_start_matches(is_space).strip_prefix('#')?;
    let rest = rest.trim_start_matches(is_space).strip_prefix("@env")?;
    let trimmed = rest.trim_start_matches(is_space);
    (trimmed.len() < rest.len()).then_some(trimmed)
}

/// Reads the name and the value of a `# @env NAME VALUE` line.
fn env_default(rest: &str) -> Option<(String, String)> {
    let mut chars = rest.char_indices();
    let (_, first) = chars.next()?;
    if !(first.is_ascii_alphabetic() || first == '_') {
        return None;
    }
    let end = chars
        .find(|(_, char)| !(char.is_ascii_alphanumeric() || *char == '_'))
        .map_or(rest.len(), |(index, _)| index);
    let value = rest[end..].trim_start_matches(is_space);
    let value = match value.strip_prefix('"') {
        Some(quoted) => quoted.split_once('"').map_or(quoted, |(inside, _)| inside),
        None => value.split(is_space).next().unwrap_or_default(),
    };
    Some((rest[..end].to_owned(), value.to_owned()))
}

/// Returns the 1-based index of the last `groups` column from the first manager field on.
fn group_column(header: &[String]) -> Option<usize> {
    header
        .iter()
        .enumerate()
        .skip(FIRST_MANAGER_FIELD - 1)
        .filter(|(_, cell)| cell.as_str() == GROUPS_COLUMN)
        .map(|(index, _)| index + 1)
        .next_back()
}

/// Splits a `groups` cell on commas, dropping empty names.
fn split_groups(cell: &str) -> Vec<&str> {
    cell.split(',').filter(|name| !name.is_empty()).collect()
}

/// Turns a list of strings into a Luau sequence.
fn sequence<S: AsRef<str>>(lua: &Lua, items: &[S]) -> crate::Result<Table> {
    let table = lua.create_table().lua()?;
    for (index, item) in items.iter().enumerate() {
        table
            .raw_set(index + 1, lua.create_string(item.as_ref()).lua()?)
            .lua()?;
    }
    Ok(table)
}

native_fn! {
    /// Reads a manifest into its data rows, with the `header` cells and the `# @env` `defaults`.
    ///
    /// Each row is `{ name, binary, fields, groups }`. The first line that is not a comment or
    /// blank is the header.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when a table cannot be built.
    #[luau = "(text: string) -> { [number]: { name: string, binary: string, fields: { string }, groups: { string } }, header: { string }, defaults: { [string]: string } }"]
    pub fn parse(lua: &Lua, text: LuaString) -> mlua::Result<Table> {
        let text = text.to_string_lossy();
        let rows = lua.create_table()?;
        let defaults = lua.create_table()?;
        rows.set("header", lua.create_table()?)?;
        rows.set("defaults", &defaults)?;
        let mut header: Option<Vec<String>> = None;
        let mut count = 0;
        for line in text.split('\n') {
            if let Some(rest) = env_rest(line) {
                if let Some((name, value)) = env_default(rest) {
                    defaults.set(name, value)?;
                }
                continue;
            }
            let trimmed = line.trim_start_matches(is_space);
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields = tokenize(line);
            let Some(columns) = &header else {
                rows.set("header", sequence(lua, &fields)?)?;
                header = Some(fields);
                continue;
            };
            let names = group_column(columns)
                .and_then(|index| fields.get(index - 1))
                .map(String::as_str)
                .map(split_groups)
                .unwrap_or_default();
            let row = lua.create_table()?;
            row.set("name", fields.first().map_or("", String::as_str))?;
            row.set("binary", fields.get(1).map_or("", String::as_str))?;
            row.set("fields", sequence(lua, &fields)?)?;
            row.set("groups", sequence(lua, &names)?)?;
            count += 1;
            rows.raw_set(count, row)?;
        }
        Ok(rows)
    }
}

native_fn! {
    /// Finds the 1-based column of a package manager in the header, or `nil` with none.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the header cannot be read.
    #[luau = "(rows: { header: { string } }, manager: string) -> number?"]
    pub fn column(_lua: &Lua, rows: Table, manager: String) -> mlua::Result<Option<usize>> {
        if manager == GROUPS_COLUMN {
            return Ok(None);
        }
        let header: Table = rows.get("header")?;
        for index in FIRST_MANAGER_FIELD..=header.raw_len() {
            if header.raw_get::<Option<String>>(index)?.as_deref() == Some(manager.as_str()) {
                return Ok(Some(index));
            }
        }
        Ok(None)
    }
}

native_struct! {
    /// Which rows `select` keeps and which cell it reads.
    pub struct SelectOpts {
        /// The manager's column from `column`.
        pub column: usize,
        /// Keeps only the rows listing this group, every row when `nil` or empty.
        pub group: Option<String>,
    }
}

/// Looks a variable up in the environment, then in the `# @env` defaults.
fn resolve(defaults: &HashMap<String, String>, name: &str, row: &str) -> crate::Result<String> {
    if let Some(value) = overlay::get(name) {
        return Ok(value);
    }
    defaults
        .get(name)
        .cloned()
        .ok_or_else(|| Error::Message(format!("Variable ${{{name}}} is undefined in row {row}.")))
}

/// Tells whether `char` can be part of a variable name.
fn is_name_char(char: char) -> bool {
    char.is_ascii_alphanumeric() || char == '_'
}

/// Expands `$NAME`, `${NAME}` and `$$` in `text`.
fn expand(defaults: &HashMap<String, String>, text: &str, row: &str) -> crate::Result<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let char = chars[i];
        let next = chars.get(i + 1).copied();
        if char != '$' {
            out.push(char);
            i += 1;
        } else if next == Some('$') {
            out.push('$');
            i += 2;
        } else if next == Some('{') {
            let close = chars[i + 2..]
                .iter()
                .position(|char| *char == '}')
                .map(|offset| i + 2 + offset);
            let name = close.map(|close| chars[i + 2..close].iter().collect::<String>());
            match (close, name) {
                (Some(close), Some(name)) if !name.is_empty() && name.chars().all(is_name_char) => {
                    out.push_str(&resolve(defaults, &name, row)?);
                    i = close + 1;
                }
                _ => {
                    out.push('$');
                    i += 1;
                }
            }
        } else if next.is_some_and(is_name_char) {
            let name: String = chars[i + 1..]
                .iter()
                .take_while(|char| is_name_char(**char))
                .collect();
            out.push_str(&resolve(defaults, &name, row)?);
            i += 1 + name.chars().count();
        } else {
            out.push('$');
            i += 1;
        }
    }
    Ok(out)
}

native_struct! {
    /// A row `select` kept, with its variables expanded.
    pub struct Selected {
        /// The row's name.
        pub name: String,
        /// The row's binary column.
        pub binary: String,
        /// The row's cell for the manager.
        pub cell: String,
    }
}

/// Expands the three cells of one row.
fn expand_row(
    defaults: &HashMap<String, String>,
    name: &str,
    binary: &str,
    cell: &str,
) -> crate::Result<Selected> {
    Ok(Selected {
        name: expand(defaults, name, name)?,
        binary: expand(defaults, binary, name)?,
        cell: expand(defaults, cell, name)?,
    })
}

native_fn! {
    /// Picks the rows of one package manager with their variables expanded.
    ///
    /// A variable takes the environment's value, else its `# @env` default. An undefined one
    /// fails the whole call with a message naming the variable and the row.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the rows cannot be read.
    #[luau = "(rows: { [number]: { name: string, binary: string, fields: { string }, groups: { string } }, defaults: { [string]: string } }, opts: { column: number, group: string? }) -> ({ { name: string, binary: string, cell: string } }?, string?)"]
    pub fn select(
        _lua: &Lua,
        rows: Table,
        opts: SelectOpts,
    ) -> mlua::Result<StdResult<Vec<Selected>, String>> {
        let defaults: HashMap<String, String> = rows
            .get::<Table>("defaults")?
            .pairs::<String, String>()
            .collect::<mlua::Result<_>>()?;
        let group = opts.group.as_deref().unwrap_or_default();
        let mut selected = Vec::new();
        for index in 1..=rows.raw_len() {
            let row: Table = rows.raw_get(index)?;
            let groups: Vec<String> = row.get::<Option<Vec<String>>>("groups")?.unwrap_or_default();
            if !group.is_empty() && !groups.iter().any(|name| name == group) {
                continue;
            }
            let name: String = row.get::<Option<String>>("name")?.unwrap_or_default();
            let binary: String = row.get::<Option<String>>("binary")?.unwrap_or_default();
            let fields: Vec<String> = row.get::<Option<Vec<String>>>("fields")?.unwrap_or_default();
            let cell = opts
                .column
                .checked_sub(1)
                .and_then(|at| fields.get(at))
                .map_or("", String::as_str);
            match expand_row(&defaults, &name, &binary, cell) {
                Ok(row) => selected.push(row),
                Err(reason) => return Ok(Err(reason.to_string())),
            }
        }
        Ok(Ok(selected))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{env_default, env_rest, expand, group_column, tokenize};

    #[test]
    fn tokenize_should_split_on_blanks_and_keep_quoted_cells() {
        assert_eq!(tokenize("a\tb  \"c d\" \"\""), vec!["a", "b", "c d", ""]);
    }

    #[test]
    fn env_default_should_read_bare_and_quoted_values() {
        let rest = env_rest("# @env SP \"asdf asdf\"").unwrap();
        assert_eq!(
            env_default(rest),
            Some(("SP".to_owned(), "asdf asdf".to_owned()))
        );
        let rest = env_rest("#@env FOO bar_value extra").unwrap();
        assert_eq!(
            env_default(rest),
            Some(("FOO".to_owned(), "bar_value".to_owned()))
        );
        assert_eq!(env_rest("# @envy x"), None);
    }

    #[test]
    fn group_column_should_skip_the_first_two_fields() {
        let header: Vec<String> = ["groups", "b", "brew", "groups"]
            .map(str::to_owned)
            .to_vec();
        assert_eq!(group_column(&header), Some(4));
        assert_eq!(group_column(&header[..3]), None);
    }

    #[test]
    fn expand_should_handle_each_form() {
        let defaults = HashMap::from([("FOO".to_owned(), "bar".to_owned())]);
        assert_eq!(
            expand(&defaults, "x-$FOO-${FOO}-$$5-$", "r").unwrap(),
            "x-bar-bar-$5-$"
        );
        assert_eq!(
            expand(&defaults, "${NOPE__X}", "r")
                .unwrap_err()
                .to_string(),
            "Variable ${NOPE__X} is undefined in row r."
        );
        assert_eq!(expand(&defaults, "${a b}", "r").unwrap(), "${a b}");
    }
}

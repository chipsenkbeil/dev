use std::fmt::Write as _;
use std::result::Result as StdResult;

use mlua::{Lua, LuaString, Table, Value};

use super::json::{OnLua, as_double};
use super::manifest::is_space;
use crate::{Error, native_fn};

/// Name of this module under `dev`.
pub const NAME: &str = "toml";

/// Why `set` refuses to write, with the string each reason has in Luau.
const REFUSALS: [(&str, &str); 5] = [
    ("BAD_KEY", "bad_key"),
    ("BAD_VALUE", "bad_value"),
    ("ALREADY_SET", "already_set"),
    ("UNPARSEABLE", "unparseable"),
    ("RESULT_INVALID", "result_invalid"),
];

/// Largest magnitude below which a whole Luau number is written as a TOML integer.
const INTEGER_LIMIT: f64 = 9.2e18;

/// Creates the `dev.toml` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be built.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    let refusals = lua.create_table()?;
    for (name, text) in REFUSALS {
        refusals.set(name, text)?;
    }
    table.set("SetRefusal", refusals)?;
    parse::register(lua, NAME, &table)?;
    set::register(lua, NAME, &table)?;
    encode::register(lua, NAME, &table)?;
    Ok(table)
}

/// Reads `text` as TOML 1.0, or words the failure as `LINE: reason`.
fn parse_tree(text: &str) -> crate::Result<::toml::Table> {
    text.parse::<::toml::Table>().map_err(|error| {
        let start = error.span().map_or(0, |span| span.start).min(text.len());
        let line = text
            .as_bytes()
            .get(..start)
            .unwrap_or_default()
            .iter()
            .filter(|byte| **byte == b'\n')
            .count()
            + 1;
        Error::Message(format!("{line}: {}", error.message()))
    })
}

/// Turns a parsed TOML value into a Luau value, with dates as their TOML text.
fn to_lua(lua: &Lua, value: &::toml::Value) -> mlua::Result<Value> {
    Ok(match value {
        ::toml::Value::String(text) => Value::String(lua.create_string(text)?),
        ::toml::Value::Integer(number) => Value::Number(*number as f64),
        ::toml::Value::Float(number) => Value::Number(*number),
        ::toml::Value::Boolean(flag) => Value::Boolean(*flag),
        ::toml::Value::Datetime(date) => Value::String(lua.create_string(date.to_string())?),
        ::toml::Value::Array(items) => {
            let table = lua.create_table()?;
            for (index, item) in items.iter().enumerate() {
                table.raw_set(index + 1, to_lua(lua, item)?)?;
            }
            Value::Table(table)
        }
        ::toml::Value::Table(map) => Value::Table(map_to_lua(lua, map)?),
    })
}

/// Turns a parsed TOML table into a Luau table.
fn map_to_lua(lua: &Lua, map: &::toml::Table) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    for (key, value) in map {
        table.raw_set(lua.create_string(key)?, to_lua(lua, value)?)?;
    }
    Ok(table)
}

native_fn! {
    /// Parses a TOML document, or returns `nil` and `LINE: reason` for the first line that fails.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when a value cannot be built.
    pub fn parse(lua: &Lua, text: LuaString) -> mlua::Result<StdResult<Table, String>> {
        let bytes = text.as_bytes();
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return Ok(Err("1: the text is not valid UTF-8".to_owned()));
        };
        match parse_tree(text) {
            Ok(tree) => Ok(Ok(map_to_lua(lua, &tree)?)),
            Err(reason) => Ok(Err(reason.to_string())),
        }
    }
}

/// Writes `text` as a TOML basic string.
fn render_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for char in text.chars() {
        match char {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            control if control.is_control() => {
                let _ = write!(out, "\\u{:04x}", u32::from(control));
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// Writes a whole Luau number as a TOML integer.
fn render_integer(number: f64) -> Option<String> {
    (number.is_finite() && number == number.floor() && number.abs() < INTEGER_LIMIT)
        .then(|| (number as i64).to_string())
}

/// Writes `value` for `set`: a string, a whole number or a list of strings.
fn render(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => text.to_str().ok().map(|text| render_string(&text)),
        Value::Integer(number) => render_integer(as_double(*number)),
        Value::Number(number) => render_integer(*number),
        Value::Table(list) if list.raw_len() > 0 => {
            let mut items = Vec::new();
            for index in 1..=list.raw_len() {
                let Ok(Value::String(item)) = list.raw_get::<Value>(index) else {
                    return None;
                };
                items.push(render_string(&item.to_str().ok()?));
            }
            Some(format!("[{}]", items.join(", ")))
        }
        _ => None,
    }
}

/// Returns the normalized table name of a `[header]` line.
fn header_of(line: &str) -> Option<String> {
    let rest = line.trim_start_matches(is_space).strip_prefix('[')?;
    let end = rest.find(['[', ']'])?;
    if !rest[end..].starts_with(']') {
        return None;
    }
    let mut inner = String::new();
    let mut chars = rest[..end].chars().peekable();
    while let Some(char) = chars.next() {
        if char == '.' {
            while chars.next_if(|next| is_space(*next)).is_some() {}
            while inner.ends_with(is_space) {
                inner.pop();
            }
        }
        inner.push(char);
    }
    Some(inner.trim_matches(is_space).to_owned())
}

/// Tells whether `line` holds anything but space and a comment.
fn is_content(line: &str) -> bool {
    let trimmed = line.trim_start_matches(is_space);
    !trimmed.is_empty() && !trimmed.starts_with('#') && line.chars().any(|char| !is_space(char))
}

/// Splits `text` into its lines, with no empty last line after a final newline.
fn split_lines(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = text.split('\n').map(str::to_owned).collect();
    if text.is_empty() || text.ends_with('\n') {
        lines.pop();
    }
    lines
}

/// Where a line scan stands: inside a multi-line string, or inside nested array brackets.
#[derive(Default)]
struct Scan {
    /// The closing delimiter of the multi-line string the scan is in.
    string: Option<&'static str>,
    /// How many array brackets are open.
    depth: usize,
}

impl Scan {
    /// Tells whether the scan is between values, so a line starts a table or a key.
    fn is_outside(&self) -> bool {
        self.string.is_none() && self.depth == 0
    }

    /// Moves the scan over `line`.
    fn feed(&mut self, line: &str) {
        let mut rest = line;
        while let Some(char) = rest.chars().next() {
            if let Some(close) = self.string {
                match rest.find(close) {
                    Some(at) => {
                        rest = &rest[at + close.len()..];
                        self.string = None;
                    }
                    None => return,
                }
                continue;
            }
            match char {
                '#' => return,
                '[' => self.depth += 1,
                ']' => self.depth = self.depth.saturating_sub(1),
                '"' | '\'' => {
                    let triple = rest.starts_with(&char.to_string().repeat(3));
                    if triple {
                        self.string = Some(if char == '"' { "\"\"\"" } else { "'''" });
                        rest = &rest[3..];
                        continue;
                    }
                    rest = skip_quoted(rest, char);
                    continue;
                }
                _ => {}
            }
            rest = &rest[char.len_utf8()..];
        }
    }
}

/// Returns `text` after the single-line string that opens it with `quote`.
fn skip_quoted(text: &str, quote: char) -> &str {
    let mut chars = text.char_indices().skip(1);
    while let Some((at, char)) = chars.next() {
        if char == '\\' && quote == '"' {
            chars.next();
        } else if char == quote {
            return &text[at + 1..];
        }
    }
    ""
}

/// Returns how many lines to keep before a new key of `section`, or `None` with no such place.
fn insertion_point(lines: &[String], section: &str) -> Option<usize> {
    let mut at = None;
    let mut inside = section.is_empty();
    let mut scan = Scan::default();
    let mut value_open = false;
    for (index, line) in lines.iter().enumerate() {
        if scan.is_outside() && line.trim_start_matches(is_space).starts_with('[') {
            if section.is_empty() {
                break;
            }
            inside = header_of(line).as_deref() == Some(section);
            if inside {
                at = Some(index + 1);
            }
            continue;
        }
        if scan.is_outside() && inside && is_content(line) {
            value_open = true;
        }
        scan.feed(line);
        if value_open && scan.is_outside() {
            at = Some(index + 1);
            value_open = false;
        }
    }
    at
}

/// Tells whether `key` is a dotted key `set` accepts.
fn is_set_key(key: &str) -> bool {
    let word = |char: char| char.is_ascii_alphanumeric() || char == '_' || char == '-';
    if key.contains("..") {
        return false;
    }
    if !key.is_empty() && key.chars().all(word) {
        return true;
    }
    let Some((first, rest)) = key.split_once('.') else {
        return false;
    };
    !first.is_empty()
        && first.chars().all(word)
        && rest.chars().all(|char| word(char) || char == '.')
        && rest.chars().next_back().is_some_and(word)
}

/// Tells whether `tree` holds the dotted `key`.
fn holds_key(tree: &::toml::Table, key: &str) -> bool {
    let mut parts = key.split('.');
    let mut node = parts.next().and_then(|first| tree.get(first));
    for part in parts {
        node = node
            .and_then(::toml::Value::as_table)
            .and_then(|table| table.get(part));
    }
    node.is_some()
}

/// What `set` gives back: the text, or nothing with the reason and its detail.
type SetOutcome = (Option<String>, Option<String>, Option<String>);

/// Adds `key` to `text` under its section, line for line otherwise.
fn set_key(text: &str, key: &str, value: &Value) -> SetOutcome {
    let refuse = |reason: &str| (None, Some(reason.to_owned()), None);
    if !is_set_key(key) {
        return refuse("bad_key");
    }
    let tree = match parse_tree(text) {
        Ok(tree) => tree,
        Err(message) => {
            return (
                None,
                Some("unparseable".to_owned()),
                Some(message.to_string()),
            );
        }
    };
    if holds_key(&tree, key) {
        return refuse("already_set");
    }
    let Some(rendered) = render(value) else {
        return refuse("bad_value");
    };
    let (section, leaf) = key.rsplit_once('.').unwrap_or(("", key));
    let eol = if text.contains("\r\n") { "\r" } else { "" };
    let entry = format!("{leaf} = {rendered}{eol}");
    let mut lines = split_lines(text);
    match insertion_point(&lines, section) {
        Some(at) => lines.insert(at, entry),
        None if section.is_empty() => lines.insert(0, entry),
        None => {
            if lines
                .last()
                .is_some_and(|last| last.chars().any(|char| !is_space(char)))
            {
                lines.push(eol.to_owned());
            }
            lines.push(format!("[{section}]{eol}"));
            lines.push(entry);
        }
    }
    let result = format!("{}\n", lines.join("\n"));
    match parse_tree(&result) {
        Ok(parsed) if holds_key(&parsed, key) => (Some(result), None, None),
        Ok(_) => (
            None,
            Some("result_invalid".to_owned()),
            Some("the key did not land in its section".to_owned()),
        ),
        Err(message) => (
            None,
            Some("result_invalid".to_owned()),
            Some(message.to_string()),
        ),
    }
}

native_fn! {
    /// Adds the dotted `key` to a TOML document under its section and keeps every other line.
    ///
    /// Returns the new text, or `nil`, the reason (`bad_key`, `bad_value`, `already_set`,
    /// `unparseable` or `result_invalid`) and a detail for the two parse reasons.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the text is not a string.
    pub fn set(
        _lua: &Lua,
        text: LuaString,
        key: String,
        value: Value,
    ) -> mlua::Result<SetOutcome> {
        let bytes = text.as_bytes();
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return Ok((None, Some("unparseable".to_owned()), Some("1: the text is not valid UTF-8".to_owned())));
        };
        Ok(set_key(text, &key, &value))
    }
}

/// Writes a key, bare when it can be.
fn render_key(key: &str) -> String {
    let bare = !key.is_empty()
        && key
            .chars()
            .all(|char| char.is_ascii_alphanumeric() || char == '_' || char == '-');
    if bare {
        key.to_owned()
    } else {
        render_string(key)
    }
}

/// Writes a Luau number as a TOML integer or float.
fn render_number(number: f64) -> String {
    if let Some(integer) = render_integer(number) {
        integer
    } else if number.is_nan() {
        "nan".to_owned()
    } else if number.is_infinite() {
        if number < 0.0 { "-inf" } else { "inf" }.to_owned()
    } else if number == number.floor() {
        format!("{number:e}")
    } else {
        format!("{number}")
    }
}

/// Tells whether `table` is a list: it has `1..n` keys and no others.
fn is_list(table: &Table) -> crate::Result<bool> {
    let length = table.raw_len();
    let mut count = 0;
    for pair in table.pairs::<Value, Value>() {
        pair.lua()?;
        count += 1;
    }
    Ok(length > 0 && count == length)
}

/// Writes `value` on one line.
fn render_inline(value: &Value) -> crate::Result<String> {
    Ok(match value {
        Value::Boolean(flag) => flag.to_string(),
        Value::Integer(number) => render_number(as_double(*number)),
        Value::Number(number) => render_number(*number),
        Value::String(text) => render_string(&text.to_str().lua()?),
        Value::Table(table) if is_list(table)? => {
            let mut items = Vec::new();
            for item in table.sequence_values::<Value>() {
                items.push(render_inline(&item.lua()?)?);
            }
            format!("[{}]", items.join(", "))
        }
        Value::Table(table) => {
            let mut fields = Vec::new();
            for (key, entry) in entries(table)? {
                fields.push(format!("{} = {}", render_key(&key), render_inline(&entry)?));
            }
            if fields.is_empty() {
                "{}".to_owned()
            } else {
                format!("{{ {} }}", fields.join(", "))
            }
        }
        other => {
            return Err(Error::Message(format!(
                "cannot encode a {} as TOML",
                other.type_name()
            )));
        }
    })
}

/// Returns the entries of a table sorted by key, raising on a key that is not a string.
fn entries(table: &Table) -> crate::Result<Vec<(String, Value)>> {
    let mut out = Vec::new();
    for pair in table.pairs::<Value, Value>() {
        let (key, value) = pair.lua()?;
        let Value::String(key) = key else {
            return Err(Error::Message(format!(
                "TOML key is not a string: {}",
                key.type_name()
            )));
        };
        out.push((key.to_str().lua()?.to_owned(), value));
    }
    out.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(out)
}

/// Tells whether `value` is a table that holds fields, not a list.
fn as_map(value: &Value) -> crate::Result<Option<&Table>> {
    match value {
        Value::Table(table) if !is_list(table)? => Ok(Some(table)),
        _ => Ok(None),
    }
}

/// Returns the tables of a list that holds only tables, and `None` for any other value.
fn table_list(value: &Value) -> crate::Result<Option<Vec<Table>>> {
    let Value::Table(list) = value else {
        return Ok(None);
    };
    if !is_list(list)? {
        return Ok(None);
    }
    let mut tables = Vec::new();
    for item in list.sequence_values::<Value>() {
        match item.lua()? {
            Value::Table(table) if !is_list(&table)? => tables.push(table),
            _ => return Ok(None),
        }
    }
    Ok(Some(tables))
}

/// Writes `table` under the header `path` when `with_header` is set, then its sub-tables.
fn render_section(
    out: &mut String,
    path: &[String],
    table: &Table,
    with_header: bool,
) -> crate::Result<()> {
    let fields = entries(table)?;
    let mut scalars = Vec::new();
    let mut maps = Vec::new();
    let mut lists = Vec::new();
    for (key, value) in &fields {
        if let Some(map) = as_map(value)? {
            maps.push((key, map));
        } else if let Some(tables) = table_list(value)? {
            lists.push((key, tables));
        } else {
            scalars.push((key, value));
        }
    }
    if with_header && !path.is_empty() && (!scalars.is_empty() || fields.is_empty()) {
        if !out.is_empty() {
            out.push('\n');
        }
        let _ = writeln!(out, "[{}]", path.join("."));
    }
    for (key, value) in scalars {
        let _ = writeln!(out, "{} = {}", render_key(key), render_inline(value)?);
    }
    for (key, map) in maps {
        let mut child = path.to_vec();
        child.push(render_key(key));
        render_section(out, &child, map, true)?;
    }
    for (key, tables) in lists {
        let mut child = path.to_vec();
        child.push(render_key(key));
        for item in &tables {
            if !out.is_empty() {
                out.push('\n');
            }
            let _ = writeln!(out, "[[{}]]", child.join("."));
            render_section(out, &child, item, false)?;
        }
    }
    Ok(())
}

native_fn! {
    /// Writes a table as TOML text, so `parse(encode(t))` equals `t`.
    ///
    /// # Errors
    ///
    /// Raises when a key is not a string or a value is not a string, number, boolean or table.
    pub fn encode(_lua: &Lua, tree: Table) -> mlua::Result<String> {
        let mut out = String::new();
        render_section(&mut out, &[], &tree, true)?;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use mlua::Lua;

    use super::{header_of, is_set_key, parse_tree, set_key, split_lines};

    fn set_text(text: &str, key: &str, value: &str) -> Option<String> {
        let lua = Lua::new();
        let value = mlua::Value::String(lua.create_string(value).unwrap());
        set_key(text, key, &value).0
    }

    #[test]
    fn set_key_should_skip_a_multi_line_string_and_its_blank_and_comment_lines() {
        let text = "[a]\nx = \"\"\"\nfirst\n\n# not a comment\n[b]\n\"\"\"\ny = 1\n";
        let out = set_text(text, "a.z", "v").unwrap();
        assert_eq!(
            out,
            "[a]\nx = \"\"\"\nfirst\n\n# not a comment\n[b]\n\"\"\"\ny = 1\nz = \"v\"\n"
        );
        let tree = parse_tree(&out).unwrap();
        assert!(tree["a"].as_table().unwrap().contains_key("z"));
    }

    #[test]
    fn set_key_should_place_a_key_after_a_multi_line_array() {
        let text = "[a]\nxs = [\n    1,\n    [2],\n]\n[b]\nn = 1\n";
        let out = set_text(text, "a.z", "v").unwrap();
        assert_eq!(
            out,
            "[a]\nxs = [\n    1,\n    [2],\n]\nz = \"v\"\n[b]\nn = 1\n"
        );
    }

    #[test]
    fn set_key_should_write_crlf_lines_in_a_crlf_file() {
        let out = set_text("[a]\r\nx = 1\r\n", "b.y", "v").unwrap();
        assert_eq!(out, "[a]\r\nx = 1\r\n\r\n[b]\r\ny = \"v\"\r\n");
        let out = set_text("[a]\r\nx = 1\r\n", "a.y", "v").unwrap();
        assert_eq!(out, "[a]\r\nx = 1\r\ny = \"v\"\r\n");
    }

    #[test]
    fn parse_tree_should_name_the_line_of_a_failure() {
        let message = parse_tree("a = 1\nb 2\n").unwrap_err().to_string();
        assert!(message.starts_with("2: "), "{message}");
    }

    #[test]
    fn header_of_should_normalize_spaces_around_dots() {
        assert_eq!(header_of("  [ a . b ] # c").as_deref(), Some("a.b"));
        assert_eq!(header_of("[[a]]"), None);
        assert_eq!(header_of("a = 1"), None);
    }

    #[test]
    fn is_set_key_should_accept_dotted_words_only() {
        assert!(is_set_key("a"));
        assert!(is_set_key("board.pomb.token"));
        assert!(!is_set_key("a..b"));
        assert!(!is_set_key("a b"));
        assert!(!is_set_key("a."));
        assert!(!is_set_key(".a"));
    }

    #[test]
    fn split_lines_should_drop_the_empty_line_after_a_final_newline() {
        assert_eq!(split_lines(""), Vec::<String>::new());
        assert_eq!(split_lines("a\n"), vec!["a"]);
        assert_eq!(split_lines("a\n\n"), vec!["a", ""]);
        assert_eq!(split_lines("a"), vec!["a"]);
    }
}

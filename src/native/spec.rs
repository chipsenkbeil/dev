use std::collections::HashSet;
use std::result::Result as StdResult;

use mlua::{Lua, MultiValue, Table, Value};

use crate::{Error, Result, native_fn};

/// Name of this module under `dev`.
pub const NAME: &str = "spec";

/// The only precondition word a spec's `requires` list may hold.
const KNOWN_REQUIRES: &[&str] = &["workspace"];

/// The spec field that lists the help pages `dev help` points at.
pub const SEE_ALSO_FIELD: &str = "see_also";

/// Fields a spec may hold.
const SPEC_FIELDS: &[&str] = &[
    "summary",
    "group",
    "hidden",
    "remote",
    "runs_local",
    "requires",
    "positional",
    "fetch",
    "patch",
    "flags",
    "args",
    "passthrough",
    "pass_unknown",
    "globals",
    "run",
    "long",
    SEE_ALSO_FIELD,
];

/// Fields a flag may hold.
const FLAG_FIELDS: &[&str] = &[
    "name",
    "short",
    "kind",
    "help",
    "default",
    "repeatable",
    "required",
    "choices",
    "complete",
    "hidden",
];

/// Fields an arg may hold.
const ARG_FIELDS: &[&str] = &["name", "help", "required", "list", "rest", "complete"];

/// Fields of a `fetch` or `patch` table.
const FETCH_FIELDS: &[&str] = &["job", "file"];

/// The kind of value a flag takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    /// Any word.
    String,
    /// A finite number.
    Number,
    /// No value: present or not.
    Boolean,
}

/// One flag of a spec, read and checked.
#[derive(Debug)]
struct FlagDef {
    /// The name after `--`.
    name: String,
    /// The key in the opts table, the name with `-` turned to `_`.
    key: String,
    /// The one letter after `-`.
    short: Option<char>,
    /// What the flag takes.
    kind: Kind,
    /// The words a string flag may take.
    choices: Option<Vec<String>>,
    /// Whether the flag may repeat and gathers a list.
    repeatable: bool,
    /// Whether the flag must be given.
    required: bool,
    /// The value of a flag that is not given.
    default: Option<Value>,
}

/// One positional arg of a spec, read and checked.
#[derive(Debug)]
struct ArgDef {
    /// The key in the args table.
    name: String,
    /// Whether the arg must be given.
    required: bool,
    /// Whether the arg takes every remaining word.
    list: bool,
    /// Whether the list arg takes the words from its first one on verbatim, flags included.
    rest: bool,
}

/// The parts of a spec the parser reads.
#[derive(Debug)]
struct Def {
    /// The flags, in order.
    flags: Vec<FlagDef>,
    /// The args, in order.
    args: Vec<ArgDef>,
    /// Whether words after `--` go to the command.
    passthrough: bool,
    /// Whether words and flags the spec does not declare go to the trailing list arg.
    pass_unknown: bool,
}

/// Fails with `reason`, a sentence for the person who wrote the spec.
fn fail<T>(reason: String) -> Result<T> {
    Err(Error::Message(reason))
}

/// The code [`validate`] returns for a spec that declares a flag taking `--help` or `-h`.
pub const RESERVED_FLAG: &str = "reserved_flag";

/// Whether a flag of the spec is named `help` or takes the short `h`.
fn declares_help(spec: &Table) -> bool {
    let Ok(Value::Table(flags)) = spec.get::<Value>("flags") else {
        return false;
    };
    flags
        .sequence_values::<Table>()
        .filter_map(StdResult::ok)
        .any(|flag| {
            let word = |key: &str| flag.get::<Option<String>>(key).ok().flatten();
            word("name").as_deref() == Some("help") || word("short").as_deref() == Some("h")
        })
}

/// Reads an optional string field.
fn string_field(table: &Table, key: &str, what: &str) -> Result<Option<String>> {
    match table.get::<Value>(key) {
        Ok(Value::Nil) => Ok(None),
        Ok(Value::String(text)) => Ok(Some(text.to_string_lossy())),
        _ => fail(format!("The {what} field `{key}` must be a string.")),
    }
}

/// Reads an optional boolean field.
fn bool_field(table: &Table, key: &str, what: &str) -> Result<Option<bool>> {
    match table.get::<Value>(key) {
        Ok(Value::Nil) => Ok(None),
        Ok(Value::Boolean(value)) => Ok(Some(value)),
        _ => fail(format!("The {what} field `{key}` must be true or false.")),
    }
}

/// Reads an optional field that is a list, and returns its items in order.
fn list_field(table: &Table, key: &str, what: &str) -> Result<Option<Vec<Value>>> {
    let wrong = || Error::Message(format!("The {what} field `{key}` must be a list."));
    let value = match table.get::<Value>(key) {
        Ok(Value::Nil) => return Ok(None),
        Ok(Value::Table(value)) => value,
        _ => return Err(wrong()),
    };
    let mut count = 0_usize;
    for pair in value.pairs::<Value, Value>() {
        pair.map_err(|_| wrong())?;
        count += 1;
    }
    let mut items = Vec::with_capacity(count);
    for index in 1..=count {
        match value.raw_get::<Value>(index) {
            Ok(Value::Nil) | Err(_) => return Err(wrong()),
            Ok(item) => items.push(item),
        }
    }
    Ok(Some(items))
}

/// Reads an optional list of strings.
fn strings_field(table: &Table, key: &str, what: &str) -> Result<Option<Vec<String>>> {
    let Some(items) = list_field(table, key, what)? else {
        return Ok(None);
    };
    let mut words = Vec::with_capacity(items.len());
    for item in items {
        match item {
            Value::String(text) => words.push(text.to_string_lossy()),
            _ => return fail(format!("The {what} field `{key}` must hold only strings.")),
        }
    }
    Ok(Some(words))
}

/// Refuses a key that is not one of `known`.
fn known_keys(table: &Table, known: &[&str], what: &str) -> Result<()> {
    for pair in table.pairs::<Value, Value>() {
        let (key, _) = pair.map_err(|error| Error::Message(error.to_string()))?;
        match key {
            Value::String(text) if known.contains(&text.to_string_lossy().as_str()) => {}
            Value::String(text) => {
                return fail(format!(
                    "The {what} field `{}` is not one dev knows.",
                    text.to_string_lossy()
                ));
            }
            other => {
                return fail(format!(
                    "The {what} holds a key of type {}, and its keys must be field names.",
                    other.type_name()
                ));
            }
        }
    }
    Ok(())
}

/// Checks that `complete` is a list, a provider name or a function.
fn complete_field(table: &Table, what: &str) -> Result<()> {
    match table.get::<Value>("complete") {
        Ok(Value::Nil | Value::String(_) | Value::Table(_) | Value::Function(_)) => Ok(()),
        _ => fail(format!(
            "The {what} field `complete` must be a list, a provider name or a function."
        )),
    }
}

/// Checks a name is a word of letters, digits, `_` and `-`.
fn word_ok(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|first| first.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Reads the `short` field of a flag.
fn read_short(table: &Table, what: &str) -> Result<Option<char>> {
    let Some(text) = string_field(table, "short", what)? else {
        return Ok(None);
    };
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (Some(letter), None) if letter.is_ascii_alphanumeric() && letter != 'h' => Ok(Some(letter)),
        _ => fail(format!(
            "The {what} field `short` must be one letter or digit other than `h`."
        )),
    }
}

/// Reads the `default` field of a flag and checks it against the flag's kind.
fn read_default(table: &Table, what: &str, kind: Kind, repeatable: bool) -> Result<Option<Value>> {
    let value = match table.get::<Value>("default") {
        Ok(Value::Nil) => return Ok(None),
        Ok(value) => value,
        Err(error) => return fail(error.to_string()),
    };
    let fits = matches!(
        (&value, kind, repeatable),
        (Value::Table(_), _, true)
            | (Value::String(_), Kind::String, false)
            | (Value::Boolean(_), Kind::Boolean, false)
            | (Value::Number(_) | Value::Integer(_), Kind::Number, false)
    );
    if fits {
        Ok(Some(value))
    } else {
        fail(format!(
            "The {what} field `default` does not match the flag's kind."
        ))
    }
}

/// Reads and checks one flag.
fn read_flag(table: &Table, index: usize) -> Result<FlagDef> {
    let what = format!("flag {index}");
    known_keys(table, FLAG_FIELDS, &what)?;
    let name = string_field(table, "name", &what)?
        .ok_or_else(|| Error::Message(format!("The {what} has no `name` field.")))?;
    let what = format!("flag `{name}`");
    if !word_ok(&name) {
        return fail(format!(
            "The {what} field `name` must be letters, digits, `_` and `-`."
        ));
    }
    if name == "help" {
        return fail(format!(
            "The {what} field `name` is reserved, because `--help` is dev's own."
        ));
    }
    let short = read_short(table, &what)?;
    let kind = match string_field(table, "kind", &what)?.as_deref() {
        None | Some("string") => Kind::String,
        Some("number") => Kind::Number,
        Some("boolean") => Kind::Boolean,
        Some(other) => {
            return fail(format!(
                "The {what} field `kind` must be string, number or boolean, not `{other}`."
            ));
        }
    };
    let choices = strings_field(table, "choices", &what)?;
    if choices.is_some() && kind != Kind::String {
        return fail(format!(
            "The {what} field `choices` is only for a flag of kind string."
        ));
    }
    let repeatable = bool_field(table, "repeatable", &what)?.unwrap_or(false);
    if repeatable && kind == Kind::Boolean {
        return fail(format!(
            "The {what} field `repeatable` cannot be set on a boolean flag."
        ));
    }
    let required = bool_field(table, "required", &what)?.unwrap_or(false);
    bool_field(table, "hidden", &what)?;
    string_field(table, "help", &what)?;
    complete_field(table, &what)?;
    let default = read_default(table, &what, kind, repeatable)?;
    Ok(FlagDef {
        key: name.replace('-', "_"),
        name,
        short,
        kind,
        choices,
        repeatable,
        required,
        default,
    })
}

/// Reads and checks one arg.
fn read_arg(table: &Table, index: usize) -> Result<ArgDef> {
    let what = format!("arg {index}");
    known_keys(table, ARG_FIELDS, &what)?;
    let name = string_field(table, "name", &what)?
        .ok_or_else(|| Error::Message(format!("The {what} has no `name` field.")))?;
    let what = format!("arg `{name}`");
    if !word_ok(&name) {
        return fail(format!(
            "The {what} field `name` must be letters, digits, `_` and `-`."
        ));
    }
    string_field(table, "help", &what)?;
    complete_field(table, &what)?;
    let list = bool_field(table, "list", &what)?.unwrap_or(false);
    let rest = bool_field(table, "rest", &what)?.unwrap_or(false);
    if rest && !list {
        return fail(format!("The {what} sets `rest`, so it needs `list` too."));
    }
    Ok(ArgDef {
        name,
        required: bool_field(table, "required", &what)?.unwrap_or(false),
        list,
        rest,
    })
}

/// Checks a `fetch` or `patch` table.
fn check_fetch(table: &Table, key: &str) -> Result<()> {
    let what = format!("spec field `{key}`");
    let value = match table.get::<Value>(key) {
        Ok(Value::Nil) => return Ok(()),
        Ok(Value::Table(value)) => value,
        _ => return fail(format!("The {what} must be a table.")),
    };
    known_keys(&value, FETCH_FIELDS, &what)?;
    for field in FETCH_FIELDS {
        let text = string_field(&value, field, &what)?;
        if text.is_none_or(|text| text.is_empty()) {
            return fail(format!("The {what} needs a non-empty `{field}` string."));
        }
    }
    Ok(())
}

/// Reads the flags of a spec.
fn read_flags(spec: &Table) -> Result<Vec<FlagDef>> {
    let mut flags: Vec<FlagDef> = Vec::new();
    let mut shorts = HashSet::new();
    let items = list_field(spec, "flags", "spec")?.unwrap_or_default();
    for (position, item) in items.into_iter().enumerate() {
        let Value::Table(table) = item else {
            return fail("The spec field `flags` must hold only tables.".to_owned());
        };
        let flag = read_flag(&table, position + 1)?;
        if flags.iter().any(|before| before.key == flag.key) {
            return fail(format!("The spec names the flag `{}` twice.", flag.name));
        }
        if let Some(short) = flag.short
            && !shorts.insert(short)
        {
            return fail(format!("The spec gives the short `-{short}` to two flags."));
        }
        flags.push(flag);
    }
    Ok(flags)
}

/// Reads the args of a spec.
fn read_args(spec: &Table) -> Result<Vec<ArgDef>> {
    let mut args: Vec<ArgDef> = Vec::new();
    let items = list_field(spec, "args", "spec")?.unwrap_or_default();
    for (position, item) in items.into_iter().enumerate() {
        let Value::Table(table) = item else {
            return fail("The spec field `args` must hold only tables.".to_owned());
        };
        let arg = read_arg(&table, position + 1)?;
        if let Some(last) = args.last() {
            if last.list {
                return fail(format!(
                    "The arg `{}` is a list, so it must be the last arg, before `{}`.",
                    last.name, arg.name
                ));
            }
            if arg.required && !last.required {
                return fail(format!(
                    "The arg `{}` is required but follows the optional arg `{}`.",
                    arg.name, last.name
                ));
            }
        }
        if args.iter().any(|before| before.name == arg.name) {
            return fail(format!("The spec names the arg `{}` twice.", arg.name));
        }
        args.push(arg);
    }
    Ok(args)
}

/// Reads every field of a spec and checks it.
fn read(spec: &Table) -> Result<Def> {
    known_keys(spec, SPEC_FIELDS, "spec")?;
    for key in ["summary", "group"] {
        string_field(spec, key, "spec")?;
    }
    for key in ["hidden", "remote", "runs_local", "positional", "globals"] {
        bool_field(spec, key, "spec")?;
    }
    let passthrough = bool_field(spec, "passthrough", "spec")?.unwrap_or(false);
    let pass_unknown = bool_field(spec, "pass_unknown", "spec")?.unwrap_or(false);
    string_field(spec, "long", "spec")?;
    if matches!(spec.get::<Value>(SEE_ALSO_FIELD), Ok(Value::String(_))) {
        return fail(format!(
            "The spec field `{SEE_ALSO_FIELD}` must be a list of help page names, such as \
             `{SEE_ALSO_FIELD} = {{ \"boards\" }}`."
        ));
    }
    strings_field(spec, SEE_ALSO_FIELD, "spec")?;
    for word in strings_field(spec, "requires", "spec")?.unwrap_or_default() {
        if !KNOWN_REQUIRES.contains(&word.as_str()) {
            return fail(format!(
                "The spec field `requires` names `{word}`, which dev does not know."
            ));
        }
    }
    check_fetch(spec, "fetch")?;
    check_fetch(spec, "patch")?;
    match spec.get::<Value>("run") {
        Ok(Value::Nil | Value::Function(_)) => {}
        _ => return fail("The spec field `run` must be a function.".to_owned()),
    }
    let flags = read_flags(spec)?;
    let args = read_args(spec)?;
    if pass_unknown && !args.last().is_some_and(|arg| arg.list) {
        return fail(
            "The spec field `pass_unknown` needs a trailing arg with `list` set.".to_owned(),
        );
    }
    Ok(Def {
        flags,
        args,
        passthrough,
        pass_unknown,
    })
}

/// What one flag collected while parsing.
#[derive(Debug)]
enum Collected {
    /// A boolean flag was given.
    Present,
    /// A flag that takes one value.
    One(Value),
    /// A repeatable flag's values.
    Many(Vec<Value>),
}

/// Turns the word a flag takes into its value, checking number and choices.
fn flag_value(
    lua: &Lua,
    flag: &FlagDef,
    word: &str,
    shown: &str,
) -> mlua::Result<StdResult<Value, String>> {
    if flag.kind == Kind::Number {
        return Ok(match word.parse::<f64>() {
            Ok(number) if number.is_finite() => Ok(Value::Number(number)),
            _ => Err(format!("The flag `{shown}` needs a number, not {word}.")),
        });
    }
    if let Some(choices) = &flag.choices
        && !choices.iter().any(|choice| choice == word)
    {
        return Ok(Err(format!(
            "The flag `{shown}` takes one of {}, not {word}.",
            choices.join(", ")
        )));
    }
    Ok(Ok(Value::String(lua.create_string(word)?)))
}

/// The opts, the args and the words after `--`.
type Parsed = (Table, Table, Option<Table>);

/// The sentence for a flag the spec does not declare.
fn unknown_flag(def: &Def, flag: &str) -> String {
    if def.passthrough {
        format!("Unknown flag {flag}. Pass it after -- to reach the command.")
    } else {
        format!("Unknown flag {flag}.")
    }
}

/// Records one occurrence of a flag.
fn collect(
    lua: &Lua,
    flag: &FlagDef,
    shown: &str,
    word: Option<&str>,
    slot: &mut Option<Collected>,
) -> mlua::Result<StdResult<(), String>> {
    let Some(word) = word else {
        *slot = Some(Collected::Present);
        return Ok(Ok(()));
    };
    let value = match flag_value(lua, flag, word, shown)? {
        Ok(value) => value,
        Err(message) => return Ok(Err(message)),
    };
    if flag.repeatable {
        match slot {
            Some(Collected::Many(values)) => values.push(value),
            _ => *slot = Some(Collected::Many(vec![value])),
        }
    } else {
        *slot = Some(Collected::One(value));
    }
    Ok(Ok(()))
}

/// Copies a list default, so a command that edits its opts never edits the spec.
fn copy_list(lua: &Lua, list: &Table) -> mlua::Result<Value> {
    let copy = lua.create_table()?;
    for item in list.sequence_values::<Value>() {
        copy.push(item?)?;
    }
    Ok(Value::Table(copy))
}

/// Builds the opts table, applying defaults and the required checks.
fn build_opts(
    lua: &Lua,
    def: &Def,
    collected: Vec<Option<Collected>>,
) -> mlua::Result<StdResult<Table, String>> {
    let opts = lua.create_table()?;
    for (flag, slot) in def.flags.iter().zip(collected) {
        let value = match slot {
            Some(Collected::Present) => Value::Boolean(true),
            Some(Collected::One(value)) => value,
            Some(Collected::Many(values)) => Value::Table(lua.create_sequence_from(values)?),
            None if flag.required => {
                return Ok(Err(format!("The flag `--{}` is required.", flag.name)));
            }
            None => match (&flag.default, flag.kind, flag.repeatable) {
                (Some(Value::Table(list)), _, true) => copy_list(lua, list)?,
                (Some(value), _, _) => value.clone(),
                (None, Kind::Boolean, _) => Value::Boolean(false),
                (None, _, true) => Value::Table(lua.create_table()?),
                (None, _, false) => Value::Nil,
            },
        };
        opts.set(flag.key.as_str(), value)?;
    }
    Ok(Ok(opts))
}

/// Builds the args table from the positional words.
fn build_args(lua: &Lua, def: &Def, positional: &[&str]) -> mlua::Result<StdResult<Table, String>> {
    let args = lua.create_table()?;
    let mut rest = positional.iter();
    for arg in &def.args {
        if arg.list {
            let words: Vec<&str> = rest.by_ref().copied().collect();
            if arg.required && words.is_empty() {
                return Ok(Err(format!("The argument {} is required.", arg.name)));
            }
            args.set(arg.name.as_str(), lua.create_sequence_from(words)?)?;
        } else if let Some(word) = rest.next() {
            args.set(arg.name.as_str(), *word)?;
        } else if arg.required {
            return Ok(Err(format!("The argument {} is required.", arg.name)));
        }
    }
    if let Some(extra) = rest.next() {
        return Ok(Err(if def.args.is_empty() {
            format!("Unknown argument {extra}. This command takes no positional arguments.")
        } else {
            format!("Unexpected argument {extra}.")
        }));
    }
    Ok(Ok(args))
}

/// Whether a word reads as a flag: it starts with `-` and holds no whitespace before any `=`.
fn flag_like(word: &str) -> bool {
    let name = word.split_once('=').map_or(word, |(name, _)| name);
    word.len() > 1 && word.starts_with('-') && !name.contains(char::is_whitespace)
}

/// Whether a word looks like a flag the spec does not declare.
fn is_unknown_flag(def: &Def, word: &str) -> bool {
    if !flag_like(word) {
        return false;
    }
    if let Some(long) = word.strip_prefix("--") {
        let name = long.split_once('=').map_or(long, |(name, _)| name);
        return !def.flags.iter().any(|flag| flag.name == name);
    }
    if word.len() > 1 && word.starts_with('-') {
        for letter in word[1..].chars() {
            match def.flags.iter().find(|flag| flag.short == Some(letter)) {
                None => return true,
                Some(flag) if flag.kind != Kind::Boolean => return false,
                Some(_) => {}
            }
        }
    }
    false
}

/// Parses `argv` against a checked spec.
fn parse_with(lua: &Lua, def: &Def, argv: &[String]) -> mlua::Result<StdResult<Parsed, String>> {
    let mut collected: Vec<Option<Collected>> = def.flags.iter().map(|_| None).collect();
    let mut positional: Vec<&str> = Vec::new();
    let mut passthrough: Option<Vec<&str>> = None;
    let mut index = 0;
    while index < argv.len() {
        let word = argv[index].as_str();
        index += 1;
        if word != "--" && def.pass_unknown && is_unknown_flag(def, word) {
            positional.push(word);
            continue;
        }
        if word == "--" {
            let rest = argv[index..].iter().map(String::as_str);
            if def.passthrough {
                passthrough = Some(rest.collect());
            } else {
                positional.extend(rest);
            }
            break;
        }
        if let Some(long) = word.strip_prefix("--").filter(|_| flag_like(word)) {
            let (name, inline) = match long.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (long, None),
            };
            let shown = format!("--{name}");
            let Some(position) = def.flags.iter().position(|flag| flag.name == name) else {
                return Ok(Err(unknown_flag(def, &shown)));
            };
            let flag = &def.flags[position];
            let given = if flag.kind == Kind::Boolean {
                if inline.is_some() {
                    return Ok(Err(format!("The flag `{shown}` takes no value.")));
                }
                None
            } else if let Some(value) = inline {
                Some(value)
            } else if let Some(next) = argv.get(index) {
                index += 1;
                Some(next.as_str())
            } else {
                return Ok(Err(format!("The flag `{shown}` needs a value.")));
            };
            if let Err(message) = collect(lua, flag, &shown, given, &mut collected[position])? {
                return Ok(Err(message));
            }
        } else if flag_like(word) {
            let letters: Vec<char> = word[1..].chars().collect();
            let mut at = 0;
            while at < letters.len() {
                let letter = letters[at];
                at += 1;
                let shown = format!("-{letter}");
                let Some(position) = def.flags.iter().position(|flag| flag.short == Some(letter))
                else {
                    return Ok(Err(unknown_flag(def, &shown)));
                };
                let flag = &def.flags[position];
                if flag.kind == Kind::Boolean {
                    if let Err(message) =
                        collect(lua, flag, &shown, None, &mut collected[position])?
                    {
                        return Ok(Err(message));
                    }
                    continue;
                }
                let attached: String = letters[at..].iter().collect();
                let given = if !attached.is_empty() {
                    attached
                } else if let Some(next) = argv.get(index) {
                    index += 1;
                    next.clone()
                } else {
                    return Ok(Err(format!("The flag `{shown}` needs a value.")));
                };
                if let Err(message) =
                    collect(lua, flag, &shown, Some(&given), &mut collected[position])?
                {
                    return Ok(Err(message));
                }
                break;
            }
        } else {
            positional.push(word);
            if def
                .args
                .get(positional.len() - 1)
                .is_some_and(|arg| arg.rest)
            {
                positional.extend(argv[index..].iter().map(String::as_str));
                break;
            }
        }
    }
    let opts = match build_opts(lua, def, collected)? {
        Ok(opts) => opts,
        Err(message) => return Ok(Err(message)),
    };
    let args = match build_args(lua, def, &positional)? {
        Ok(args) => args,
        Err(message) => return Ok(Err(message)),
    };
    let passthrough = passthrough
        .map(|words| lua.create_sequence_from(words))
        .transpose()?;
    Ok(Ok((opts, args, passthrough)))
}

native_fn! {
    /// Checks every field of a command spec and returns it, or `nil`, a sentence naming the
    /// field that is wrong and, when the spec declares a flag that takes `--help` or `-h`, the
    /// code `Reason.RESERVED_FLAG`.
    ///
    /// # Errors
    ///
    /// Never fails. The result type is the one every native function shares.
    #[luau = "(spec: { [any]: any }) -> ({ [any]: any }?, string?, string?)"]
    pub fn validate(lua: &Lua, spec: Table) -> mlua::Result<MultiValue> {
        let Err(error) = read(&spec) else {
            return Ok(MultiValue::from_iter([Value::Table(spec)]));
        };
        let mut reply = vec![
            Value::Nil,
            Value::String(lua.create_string(error.to_string())?),
        ];
        if declares_help(&spec) {
            reply.push(Value::String(lua.create_string(RESERVED_FLAG)?));
        }
        Ok(MultiValue::from_iter(reply))
    }
}

native_fn! {
    /// Parses the words after a command against its spec.
    ///
    /// Returns the opts keyed by flag name with `-` as `_`, the args keyed by arg name, and the
    /// words after `--` when the spec takes them, or `nil` and a usage message.
    ///
    /// # Errors
    ///
    /// Raises when the spec is not valid, which `validate` reports first.
    #[luau = "(spec: { [any]: any }, argv: { string }) -> ({ [any]: any }?, { [any]: any }?, { string }?)"]
    pub fn parse(lua: &Lua, spec: Table, argv: Vec<String>) -> mlua::Result<MultiValue> {
        let def = read(&spec).map_err(mlua::Error::from)?;
        Ok(match parse_with(lua, &def, &argv)? {
            Ok((opts, args, passthrough)) => MultiValue::from_iter([
                Value::Table(opts),
                Value::Table(args),
                passthrough.map_or(Value::Nil, Value::Table),
            ]),
            Err(message) => MultiValue::from_iter([
                Value::Nil,
                Value::String(lua.create_string(&message)?),
            ]),
        })
    }
}

/// Creates the `dev.spec` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created or filled.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("SEE_ALSO_FIELD", SEE_ALSO_FIELD)?;
    let reasons = lua.create_table()?;
    reasons.set("RESERVED_FLAG", RESERVED_FLAG)?;
    table.set("Reason", reasons)?;
    validate::register(lua, NAME, &table)?;
    parse::register(lua, NAME, &table)?;
    Ok(table)
}

#[cfg(test)]
mod tests {
    use mlua::{Lua, Table};

    use super::{is_unknown_flag, parse_with, read};

    fn spec(lua: &Lua, source: &str) -> Table {
        lua.load(format!("return {source}")).eval().expect("spec")
    }

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    fn parsed(source: &str, argv: &str) -> Result<String, String> {
        parsed_words(source, &words(argv))
    }

    fn parsed_words(source: &str, argv: &[String]) -> Result<String, String> {
        let lua = Lua::new();
        let spec = spec(&lua, source);
        let def = read(&spec).map_err(|error| error.to_string())?;
        let (opts, args, pass) = parse_with(&lua, &def, argv).expect("lua")?;
        lua.globals().set("opts", opts).expect("set");
        lua.globals().set("args", args).expect("set");
        lua.globals().set("pass", pass).expect("set");
        lua.load(
            "local function show(t) local k = {} for key, v in pairs(t) do \
             k[#k + 1] = tostring(key) .. '=' .. (type(v) == 'table' and table.concat(v, ',') \
             or tostring(v)) end table.sort(k) return table.concat(k, ' ') end \
             return show(opts) .. ' | ' .. show(args) .. ' | ' .. \
             (pass and table.concat(pass, ',') or 'nil')",
        )
        .eval::<String>()
        .map_err(|error| error.to_string())
    }

    #[test]
    fn validate_should_take_see_also_as_a_list_of_names_only() {
        let lua = Lua::new();

        // Refuse a number
        let message = read(&spec(&lua, "{ summary = 'x', see_also = 3 }")).expect_err("number");
        assert!(message.to_string().contains("`see_also`"), "{message}");

        // Refuse a bare string and show the list form
        let message =
            read(&spec(&lua, "{ summary = 'x', see_also = 'flags' }")).expect_err("string");
        assert!(
            message.to_string().contains("see_also = { \"boards\" }"),
            "{message}"
        );

        // Refuse a list that holds a non-string
        let message =
            read(&spec(&lua, "{ summary = 'x', see_also = { 'a', 2 } }")).expect_err("item");
        assert!(message.to_string().contains("only strings"), "{message}");

        // Accept a list of page names
        read(&spec(
            &lua,
            "{ summary = 'x', see_also = { 'boards', 'flags' }, long = '# Hi' }",
        ))
        .expect("ok");
    }

    #[test]
    fn validate_should_name_an_unknown_field() {
        let lua = Lua::new();
        let message = read(&spec(&lua, "{ summary = 'x', colour = 1 }")).expect_err("unknown");
        assert!(message.to_string().contains("`colour`"), "{message}");
    }

    #[test]
    fn validate_should_refuse_a_bad_kind() {
        let lua = Lua::new();
        let message = read(&spec(
            &lua,
            "{ flags = { { name = 'a', kind = 'float' } } }",
        ))
        .expect_err("kind");
        assert!(message.to_string().contains("`kind`"), "{message}");
    }

    #[test]
    fn validate_should_refuse_choices_on_a_number() {
        let lua = Lua::new();
        let message = read(&spec(
            &lua,
            "{ flags = { { name = 'a', kind = 'number', choices = { 'x' } } } }",
        ))
        .expect_err("choices");
        assert!(message.to_string().contains("`choices`"), "{message}");
    }

    #[test]
    fn validate_should_refuse_a_list_arg_that_is_not_last() {
        let lua = Lua::new();
        let message = read(&spec(
            &lua,
            "{ args = { { name = 'a', list = true }, { name = 'b' } } }",
        ))
        .expect_err("list");
        assert!(
            message.to_string().contains("must be the last arg"),
            "{message}"
        );
    }

    #[test]
    fn validate_should_refuse_an_unknown_requires_word() {
        let lua = Lua::new();
        let message = read(&spec(&lua, "{ requires = { 'primary' } }")).expect_err("requires");
        assert!(message.to_string().contains("`requires`"), "{message}");
    }

    #[test]
    fn parse_should_read_long_short_and_boolean_flags() {
        let out = parsed(
            "{ flags = { { name = 'wait', short = 'w', kind = 'number', default = 30 }, \
             { name = 'dry-run', kind = 'boolean' } }, \
             args = { { name = 'card', required = true } } }",
            "-w 5 --dry-run 7",
        );
        assert_eq!(out, Ok("dry_run=true wait=5 | card=7 | nil".to_owned()));
    }

    #[test]
    fn parse_should_apply_defaults_and_inline_values() {
        let out = parsed(
            "{ flags = { { name = 'wait', kind = 'number', default = 30 }, \
             { name = 'label', repeatable = true } } }",
            "--label=a --label b",
        );
        assert_eq!(out, Ok("label=a,b wait=30 |  | nil".to_owned()));
    }

    #[test]
    fn parse_should_refuse_a_choice_outside_the_list() {
        let out = parsed(
            "{ flags = { { name = 'list', choices = { 'a', 'b' }, required = true } } }",
            "--list c",
        );
        assert_eq!(
            out,
            Err("The flag `--list` takes one of a, b, not c.".to_owned())
        );
    }

    #[test]
    fn parse_should_require_a_required_flag() {
        let out = parsed("{ flags = { { name = 'list', required = true } } }", "");
        assert_eq!(out, Err("The flag `--list` is required.".to_owned()));
    }

    #[test]
    fn parse_should_give_the_list_arg_the_rest() {
        let out = parsed(
            "{ args = { { name = 'a' }, { name = 'rest', list = true } } }",
            "x y z",
        );
        assert_eq!(out, Ok(" | a=x rest=y,z | nil".to_owned()));
    }

    #[test]
    fn parse_should_take_a_flags_value_verbatim_even_with_a_dash() {
        let source = "{ flags = { { name = 'text', short = 't' } } }";
        assert_eq!(
            parsed(source, "--text -x"),
            Ok("text=-x |  | nil".to_owned())
        );
        assert_eq!(
            parsed(source, "-t --nope"),
            Ok("text=--nope |  | nil".to_owned())
        );
        assert_eq!(
            parsed(source, "--text=-x"),
            Ok("text=-x |  | nil".to_owned())
        );
    }

    #[test]
    fn parse_should_never_read_a_word_with_whitespace_as_a_flag() {
        let source = "{ args = { { name = 'a', list = true } } }";
        let argv = [
            "- fixed".to_owned(),
            "--as flag".to_owned(),
            "-x y".to_owned(),
        ];
        assert_eq!(
            parsed_words(source, &argv),
            Ok(" | a=- fixed,--as flag,-x y | nil".to_owned())
        );
        let flagged = "{ flags = { { name = 'board' } } }";
        let argv = ["--board=a b".to_owned()];
        assert_eq!(
            parsed_words(flagged, &argv),
            Ok("board=a b |  | nil".to_owned())
        );
    }

    #[test]
    fn parse_should_give_a_rest_arg_every_word_from_its_first_verbatim() {
        let source = "{ flags = { { name = 'kind' } }, \
                      args = { { name = 'card' }, { name = 'text', list = true, rest = true } } }";
        assert_eq!(
            parsed(source, "--kind k c fix --kind -- --nope"),
            Ok("kind=k | card=c text=fix,--kind,--,--nope | nil".to_owned())
        );
        assert_eq!(
            parsed(source, "c --kind k hello"),
            Ok("kind=k | card=c text=hello | nil".to_owned())
        );
    }

    #[test]
    fn validate_should_refuse_rest_without_list() {
        let lua = Lua::new();
        let message = read(&spec(&lua, "{ args = { { name = 'a', rest = true } } }"))
            .expect_err("rest alone");
        assert!(message.to_string().contains("`rest`"), "{message}");
    }

    #[test]
    fn parse_should_split_passthrough_after_dashes() {
        let out = parsed("{ passthrough = true }", "-- a b");
        assert_eq!(out, Ok(" |  | a,b".to_owned()));
    }

    #[test]
    fn parse_should_fill_args_with_words_after_dashes_without_passthrough() {
        let out = parsed("{ args = { { name = 'rest', list = true } } }", "-- -a b");
        assert_eq!(out, Ok(" | rest=-a,b | nil".to_owned()));
        assert_eq!(
            parsed("{}", "-- a"),
            Err("Unknown argument a. This command takes no positional arguments.".to_owned())
        );
    }

    #[test]
    fn parse_should_refuse_an_unknown_flag_and_extra_args() {
        assert_eq!(
            parsed("{}", "--nope"),
            Err("Unknown flag --nope.".to_owned())
        );
        assert_eq!(
            parsed("{}", "x"),
            Err("Unknown argument x. This command takes no positional arguments.".to_owned())
        );
    }

    #[test]
    fn parse_should_pass_unknown_words_to_the_list_arg() {
        let out = parsed(
            "{ pass_unknown = true, flags = { { name = 'wait', kind = 'number' } }, \
             args = { { name = 'rest', list = true } } }",
            "--foo --wait 3 x -q -- y",
        );
        assert_eq!(out, Ok("wait=3 | rest=--foo,x,-q,y | nil".to_owned()));
    }

    #[test]
    fn is_unknown_flag_should_judge_a_bundle_up_to_its_first_value_flag() {
        let lua = Lua::new();
        let def = read(&spec(
            &lua,
            "{ pass_unknown = true, flags = { { name = 'wait', short = 'w', kind = 'number' }, \
             { name = 'label' }, { name = 'all', short = 'a', kind = 'boolean' } }, \
             args = { { name = 'rest', list = true } } }",
        ))
        .expect("spec");
        assert!(!is_unknown_flag(&def, "-w5"));
        assert!(!is_unknown_flag(&def, "-w=5"));
        assert!(!is_unknown_flag(&def, "-aw5"));
        assert!(is_unknown_flag(&def, "-ax"));
        assert!(is_unknown_flag(&def, "-x"));
        assert!(!is_unknown_flag(&def, "--label="));
        assert!(is_unknown_flag(&def, "--other"));
        assert!(!is_unknown_flag(&def, "-"));
    }

    #[test]
    fn parse_should_take_a_dashed_value_and_split_at_dashes_with_pass_unknown() {
        let spec = "{ pass_unknown = true, flags = { { name = 'label' } }, \
                    args = { { name = 'rest', list = true } } }";
        assert_eq!(
            parsed(spec, "--label -x y"),
            Ok("label=-x | rest=y | nil".to_owned())
        );
        assert_eq!(
            parsed(spec, "a -- --b"),
            Ok(" | rest=a,--b | nil".to_owned())
        );
    }

    #[test]
    fn validate_should_need_a_list_arg_for_pass_unknown() {
        let lua = Lua::new();
        let message = read(&spec(&lua, "{ pass_unknown = true }")).expect_err("list");
        assert!(message.to_string().contains("`pass_unknown`"), "{message}");
    }

    #[test]
    fn parse_should_refuse_a_word_that_is_no_number() {
        let out = parsed(
            "{ flags = { { name = 'wait', kind = 'number' } } }",
            "--wait soon",
        );
        assert_eq!(
            out,
            Err("The flag `--wait` needs a number, not soon.".to_owned())
        );
    }
}

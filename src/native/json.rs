use std::result::Result as StdResult;

use mlua::{Lua, LuaString, MultiValue, Table, Value};

use crate::{Error, luau, native_fn};

/// Name of this module under `dev`.
pub const NAME: &str = "json";

/// Deepest nesting `decode` reads and `encode` writes.
const MAX_DEPTH: usize = 200;

/// Registry key of the `json.null` sentinel.
const NULL_KEY: &str = "dev.json.null";

/// Registry key of the metatable that marks a table as a JSON object.
const OBJECT_META_KEY: &str = "dev.json.object";

/// Metatable field that marks a table as a JSON object.
const OBJECT_MARK: &str = "__jsonobject";

/// Smallest magnitude from which `encode` no longer writes a whole number as an integer.
const EXACT_INTEGER_LIMIT: f64 = 9_007_199_254_740_992.0;

/// Creates the `dev.json` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be built.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;

    let null = lua.create_table()?;
    let null_meta = lua.create_table()?;
    null_meta.set(
        "__tostring",
        lua.create_function(|_, _: MultiValue| Ok("json.null"))?,
    )?;
    null.set_metatable(Some(null_meta))?;
    lua.set_named_registry_value(NULL_KEY, null.clone())?;
    table.set("null", null)?;
    luau::value(
        NAME,
        "null",
        "{}".to_owned(),
        "The value `decode` gives for a JSON null and `encode` writes as one.",
    );

    let object_meta = lua.create_table()?;
    object_meta.set(OBJECT_MARK, true)?;
    lua.set_named_registry_value(OBJECT_META_KEY, object_meta)?;

    decode::register(lua, NAME, &table)?;
    encode::register(lua, NAME, &table)?;
    object::register(lua, NAME, &table)?;
    is_object::register(lua, NAME, &table)?;
    present::register(lua, NAME, &table)?;
    Ok(table)
}

/// The result of one decode or encode step.
type Step<T> = crate::Result<T>;

/// Converts a Luau number that holds an integer into the double Luau means by it.
///
/// Luau numbers are doubles, so a whole number beyond 2^53 rounds as it does in Luau.
#[expect(clippy::cast_precision_loss, reason = "Luau numbers are doubles")]
pub(super) fn as_double(integer: mlua::Integer) -> f64 {
    integer as f64
}

/// Turns a Luau error met below the boundary into dev's error.
pub(super) trait OnLua<T> {
    fn lua(self) -> Step<T>;
}

impl<T> OnLua<T> for mlua::Result<T> {
    fn lua(self) -> Step<T> {
        self.map_err(|error| Error::Message(error.to_string()))
    }
}

/// Words `reason` with the 1-based byte offset of the 0-based position `at`.
fn at_offset(at: usize, reason: &str) -> Error {
    Error::Message(format!("{reason} at offset {}", at + 1))
}

/// Returns the position of the first byte at or after `at` that is not JSON whitespace.
fn skip(text: &[u8], mut at: usize) -> usize {
    while matches!(text.get(at), Some(b' ' | b'\t' | b'\r' | b'\n')) {
        at += 1;
    }
    at
}

/// Reads four hex digits at `at`.
fn hex4(text: &[u8], at: usize) -> Option<u32> {
    let digits = text.get(at..at + 4)?;
    digits.iter().try_fold(0_u32, |code, byte| {
        let digit = char::from(*byte).to_digit(16)?;
        Some(code * 16 + digit)
    })
}

/// A JSON reader that builds Luau values.
struct Decoder<'a> {
    lua: &'a Lua,
    text: &'a [u8],
    null: Table,
    object_meta: Table,
}

impl Decoder<'_> {
    fn byte(&self, at: usize) -> Option<u8> {
        self.text.get(at).copied()
    }

    /// Reads the escape after the backslash at `stop` and returns where reading resumes.
    fn escape(&self, stop: usize, out: &mut Vec<u8>) -> Step<usize> {
        match self.byte(stop + 1) {
            Some(b'u') => {
                let Some(code) = hex4(self.text, stop + 2) else {
                    return Err(at_offset(stop, "bad unicode escape"));
                };
                let mut next = stop + 6;
                let scalar = if (0xD800..0xDC00).contains(&code) {
                    let pair = self.byte(next) == Some(b'\\') && self.byte(next + 1) == Some(b'u');
                    let low = pair
                        .then(|| hex4(self.text, next + 2))
                        .flatten()
                        .filter(|low| (0xDC00..=0xDFFF).contains(low));
                    let Some(low) = low else {
                        return Err(at_offset(stop, "unpaired surrogate"));
                    };
                    next += 6;
                    0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                } else if (0xDC00..=0xDFFF).contains(&code) {
                    return Err(at_offset(stop, "unpaired surrogate"));
                } else {
                    code
                };
                let Some(char) = char::from_u32(scalar) else {
                    return Err(at_offset(stop, "bad unicode escape"));
                };
                let mut buffer = [0_u8; 4];
                out.extend_from_slice(char.encode_utf8(&mut buffer).as_bytes());
                Ok(next)
            }
            Some(byte) => {
                let decoded = match byte {
                    b'"' | b'\\' | b'/' => byte,
                    b'b' => 0x08,
                    b'f' => 0x0C,
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    _ => return Err(at_offset(stop, "bad escape")),
                };
                out.push(decoded);
                Ok(stop + 2)
            }
            None => Err(at_offset(stop, "bad escape")),
        }
    }

    fn string(&self, at: usize) -> Step<(Vec<u8>, usize)> {
        let mut out = Vec::new();
        let mut next = at + 1;
        loop {
            let rest = self.text.get(next..).unwrap_or_default();
            let Some(offset) = rest
                .iter()
                .position(|byte| matches!(byte, b'"' | b'\\' | 0..=31))
            else {
                return Err(at_offset(self.text.len(), "unterminated string"));
            };
            let stop = next + offset;
            out.extend_from_slice(&self.text[next..stop]);
            match self.text[stop] {
                b'"' => return Ok((out, stop + 1)),
                b'\\' => next = self.escape(stop, &mut out)?,
                _ => return Err(at_offset(stop, "control character in string")),
            }
        }
    }

    fn digits(&self, at: usize) -> usize {
        self.text
            .get(at..)
            .unwrap_or_default()
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count()
    }

    fn number(&self, at: usize) -> Step<(f64, usize)> {
        let bad = || at_offset(at, "bad number");
        let sign = usize::from(self.byte(at) == Some(b'-'));
        let int = self.digits(at + sign);
        if int == 0 || (self.byte(at + sign) == Some(b'0') && int > 1) {
            return Err(bad());
        }
        let mut end = at + sign + int;
        if self.byte(end) == Some(b'.') {
            let frac = self.digits(end + 1);
            if frac == 0 {
                return Err(bad());
            }
            end += 1 + frac;
        }
        if matches!(self.byte(end), Some(b'e' | b'E')) {
            let exp_sign = usize::from(matches!(self.byte(end + 1), Some(b'+' | b'-')));
            let exp = self.digits(end + 1 + exp_sign);
            if exp == 0 {
                return Err(bad());
            }
            end += 1 + exp_sign + exp;
        }
        let literal = String::from_utf8_lossy(&self.text[at..end]);
        let number = literal.parse::<f64>().map_err(|_| bad())?;
        if number.is_infinite() {
            return Err(at_offset(at, "number out of range"));
        }
        Ok((number, end))
    }

    fn array(&self, at: usize, depth: usize) -> Step<(Value, usize)> {
        let out = self.lua.create_table().lua()?;
        let mut at = skip(self.text, at + 1);
        if self.byte(at) == Some(b']') {
            return Ok((Value::Table(out), at + 1));
        }
        let mut count = 0_i64;
        loop {
            let (value, next) = self.value(at, depth)?;
            count += 1;
            out.raw_set(count, value).lua()?;
            at = skip(self.text, next);
            match self.byte(at) {
                Some(b']') => return Ok((Value::Table(out), at + 1)),
                Some(b',') => {}
                _ => return Err(at_offset(at, "expected , or ]")),
            }
            at = skip(self.text, at + 1);
        }
    }

    fn object(&self, at: usize, depth: usize) -> Step<(Value, usize)> {
        let out = self.lua.create_table().lua()?;
        out.set_metatable(Some(self.object_meta.clone())).lua()?;
        let mut at = skip(self.text, at + 1);
        if self.byte(at) == Some(b'}') {
            return Ok((Value::Table(out), at + 1));
        }
        loop {
            if self.byte(at) != Some(b'"') {
                return Err(at_offset(at, "expected string key"));
            }
            let (key, next) = self.string(at)?;
            at = skip(self.text, next);
            if self.byte(at) != Some(b':') {
                return Err(at_offset(at, "expected :"));
            }
            let (value, next) = self.value(skip(self.text, at + 1), depth)?;
            out.raw_set(self.lua.create_string(&key).lua()?, value)
                .lua()?;
            at = skip(self.text, next);
            match self.byte(at) {
                Some(b'}') => return Ok((Value::Table(out), at + 1)),
                Some(b',') => {}
                _ => return Err(at_offset(at, "expected , or }")),
            }
            at = skip(self.text, at + 1);
        }
    }

    fn value(&self, at: usize, depth: usize) -> Step<(Value, usize)> {
        match self.byte(at) {
            Some(open @ (b'{' | b'[')) => {
                if depth >= MAX_DEPTH {
                    return Err(at_offset(at, "nesting too deep"));
                }
                if open == b'{' {
                    self.object(at, depth + 1)
                } else {
                    self.array(at, depth + 1)
                }
            }
            Some(b'"') => {
                let (text, next) = self.string(at)?;
                Ok((Value::String(self.lua.create_string(&text).lua()?), next))
            }
            Some(b'-' | b'0'..=b'9') => {
                let (number, next) = self.number(at)?;
                Ok((Value::Number(number), next))
            }
            _ => {
                let rest = self.text.get(at..).unwrap_or_default();
                if rest.starts_with(b"true") {
                    Ok((Value::Boolean(true), at + 4))
                } else if rest.starts_with(b"false") {
                    Ok((Value::Boolean(false), at + 5))
                } else if rest.starts_with(b"null") {
                    Ok((Value::Table(self.null.clone()), at + 4))
                } else if at >= self.text.len() {
                    Err(at_offset(at, "unexpected end"))
                } else {
                    Err(at_offset(at, "unexpected character"))
                }
            }
        }
    }

    fn document(&self) -> Step<Value> {
        let (value, next) = self.value(skip(self.text, 0), 0)?;
        let end = skip(self.text, next);
        if end < self.text.len() {
            return Err(at_offset(end, "unexpected trailing data"));
        }
        Ok(value)
    }
}

native_fn! {
    /// Parses one JSON document, giving `json.null` for null and `nil` and the reason on failure.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when a value cannot be built.
    pub fn decode(lua: &Lua, text: LuaString) -> mlua::Result<StdResult<Value, String>> {
        let bytes = text.as_bytes();
        let decoder = Decoder {
            lua,
            text: &bytes,
            null: lua.named_registry_value(NULL_KEY)?,
            object_meta: lua.named_registry_value(OBJECT_META_KEY)?,
        };
        match decoder.document() {
            Ok(value) => Ok(Ok(value)),
            Err(error) => Ok(Err(error.to_string())),
        }
    }
}

native_fn! {
    /// Marks `t`, or a new table, so `encode` writes it as an object even when it is empty.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the table cannot be created or marked.
    pub fn object(lua: &Lua, t: Option<Table>) -> mlua::Result<Table> {
        let table = match t {
            Some(table) => table,
            None => lua.create_table()?,
        };
        table.set_metatable(Some(lua.named_registry_value(OBJECT_META_KEY)?))?;
        Ok(table)
    }
}

/// Tells whether `table` carries the object mark.
fn marked(table: &Table) -> Step<bool> {
    let Some(meta) = table.metatable() else {
        return Ok(false);
    };
    Ok(matches!(
        meta.raw_get::<Value>(OBJECT_MARK).lua()?,
        Value::Boolean(true)
    ))
}

native_fn! {
    /// Tells whether `value` is a table that `decode` or `object` marked as an object.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the metatable cannot be read.
    pub fn is_object(_lua: &Lua, value: Value) -> mlua::Result<bool> {
        match value {
            Value::Table(table) => Ok(marked(&table)?),
            _ => Ok(false),
        }
    }
}

native_fn! {
    /// Turns the `json.null` sentinel into `nil` and returns any other value as it is.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when the sentinel cannot be read.
    pub fn present(lua: &Lua, value: Value) -> mlua::Result<Value> {
        let null: Table = lua.named_registry_value(NULL_KEY)?;
        match &value {
            Value::Table(table) if *table == null => Ok(Value::Nil),
            _ => Ok(value),
        }
    }
}

/// Formats `number` as C's `%.{digits}g` does.
fn general(number: f64, digits: usize) -> String {
    let scientific = format!("{:.*e}", digits - 1, number);
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let limit = i32::try_from(digits).unwrap_or(i32::MAX);
    let trim = |text: &str| -> String {
        if text.contains('.') {
            text.trim_end_matches('0').trim_end_matches('.').to_owned()
        } else {
            text.to_owned()
        }
    };
    if exponent < -4 || exponent >= limit {
        let sign = if exponent < 0 { '-' } else { '+' };
        format!("{}e{sign}{:02}", trim(mantissa), exponent.abs())
    } else {
        let places = usize::try_from(limit - 1 - exponent).unwrap_or(0);
        trim(&format!("{number:.places$}"))
    }
}

/// Writes `text` as a JSON string.
fn write_string(out: &mut Vec<u8>, text: &[u8]) {
    out.push(b'"');
    for &byte in text {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            0x08 => out.extend_from_slice(b"\\b"),
            0x0C => out.extend_from_slice(b"\\f"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0..=31 | 127 => out.extend_from_slice(format!("\\u{byte:04x}").as_bytes()),
            _ => out.push(byte),
        }
    }
    out.push(b'"');
}

/// Writes `number` as the shortest JSON number that reads back as the same double.
fn write_number(out: &mut Vec<u8>, number: f64) -> Step<()> {
    if number.is_nan() {
        return Err(Error::Message("cannot encode nan".to_owned()));
    }
    if number.is_infinite() {
        let sign = if number < 0.0 { "-" } else { "" };
        return Err(Error::Message(format!("cannot encode {sign}inf")));
    }
    let text = if number == number.floor() && number.abs() < EXACT_INTEGER_LIMIT {
        (number as i64).to_string()
    } else {
        [15, 16]
            .into_iter()
            .map(|digits| general(number, digits))
            .find(|text| text.parse::<f64>().is_ok_and(|back| back == number))
            .unwrap_or_else(|| general(number, 17))
    };
    out.extend_from_slice(text.as_bytes());
    Ok(())
}

/// A JSON writer that reads Luau values.
struct Encoder<'a> {
    lua: &'a Lua,
    null: Table,
    order: Vec<Vec<u8>>,
}

impl Encoder<'_> {
    fn keys(&self, table: &Table) -> Step<Vec<Vec<u8>>> {
        let mut keys: Vec<Vec<u8>> = Vec::new();
        for key in &self.order {
            let found = table
                .raw_get::<Value>(self.lua.create_string(key).lua()?)
                .lua()?;
            if !matches!(found, Value::Nil) {
                keys.push(key.clone());
            }
        }
        let placed = keys.clone();
        let mut rest: Vec<Vec<u8>> = Vec::new();
        for pair in table.pairs::<Value, Value>() {
            let (key, _) = pair.lua()?;
            let Value::String(key) = key else {
                let shown = key
                    .to_string()
                    .unwrap_or_else(|_| key.type_name().to_owned());
                return Err(Error::Message(format!(
                    "object key is not a string: {shown}"
                )));
            };
            let bytes = key.as_bytes().to_vec();
            if !placed.contains(&bytes) {
                rest.push(bytes);
            }
        }
        rest.sort();
        keys.extend(rest);
        Ok(keys)
    }

    fn value(&self, out: &mut Vec<u8>, value: &Value, depth: usize) -> Step<()> {
        match value {
            Value::Boolean(flag) => out.extend_from_slice(if *flag { b"true" } else { b"false" }),
            Value::Integer(integer) => write_number(out, as_double(*integer))?,
            Value::Number(number) => write_number(out, *number)?,
            Value::String(text) => write_string(out, &text.as_bytes()),
            Value::Table(table) if *table == self.null => out.extend_from_slice(b"null"),
            Value::Table(table) => {
                if depth >= MAX_DEPTH {
                    return Err(Error::Message("nesting too deep".to_owned()));
                }
                self.table(out, table, depth)?;
            }
            other => {
                return Err(Error::Message(format!(
                    "cannot encode a {}",
                    other.type_name()
                )));
            }
        }
        Ok(())
    }

    fn table(&self, out: &mut Vec<u8>, table: &Table, depth: usize) -> Step<()> {
        let mut count = 0_i64;
        for pair in table.pairs::<Value, Value>() {
            pair.lua()?;
            count += 1;
        }
        let mut is_array = !marked(table)?;
        for index in 1..=count {
            if !is_array {
                break;
            }
            is_array = !matches!(table.raw_get::<Value>(index).lua()?, Value::Nil);
        }
        if is_array {
            out.push(b'[');
            for index in 1..=count {
                if index > 1 {
                    out.push(b',');
                }
                self.value(out, &table.raw_get(index).lua()?, depth + 1)?;
            }
            out.push(b']');
            return Ok(());
        }
        out.push(b'{');
        for (position, key) in self.keys(table)?.iter().enumerate() {
            if position > 0 {
                out.push(b',');
            }
            write_string(out, key);
            out.push(b':');
            let entry = table
                .raw_get::<Value>(self.lua.create_string(key).lua()?)
                .lua()?;
            self.value(out, &entry, depth + 1)?;
        }
        out.push(b'}');
        Ok(())
    }
}

native_fn! {
    /// Writes `value` as compact JSON with a stable key order, or returns `nil` and the reason.
    ///
    /// `opts.order` lists the keys that come first at every level. The rest are sorted.
    ///
    /// # Errors
    ///
    /// Returns the Lua error when a table cannot be read.
    #[luau = "(value: any, opts: { order: { string }? }?) -> (string?, string?)"]
    pub fn encode(
        lua: &Lua,
        value: Value,
        opts: Option<Table>,
    ) -> mlua::Result<StdResult<LuaString, String>> {
        let listed = match opts {
            Some(opts) => opts.get::<Option<Table>>("order")?,
            None => None,
        };
        let order = match listed {
            Some(list) => list
                .sequence_values::<LuaString>()
                .map(|key| key.map(|key| key.as_bytes().to_vec()))
                .collect::<mlua::Result<Vec<_>>>()?,
            None => Vec::new(),
        };
        let encoder = Encoder { lua, null: lua.named_registry_value(NULL_KEY)?, order };
        let mut out = Vec::new();
        match encoder.value(&mut out, &value, 0) {
            Ok(()) => Ok(Ok(lua.create_string(&out)?)),
            Err(error) => Ok(Err(error.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::general;

    #[test]
    fn general_should_match_c_percent_g() {
        assert_eq!(general(1e300, 15), "1e+300");
        assert_eq!(general(-0.5, 15), "-0.5");
        assert_eq!(general(0.1, 17), "0.10000000000000001");
        assert_eq!(general(1e-7, 15), "1e-07");
        assert_eq!(general(123_456.789, 15), "123456.789");
        assert_eq!(general(1.5e20, 15), "1.5e+20");
    }
}

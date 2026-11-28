use std::collections::{BTreeMap, HashMap};
use std::result::Result as StdResult;
use std::sync::{Mutex, PoisonError};

use mlua::{AnyUserData, Function, LuaString, MultiValue, Table, Value, Variadic};

/// Signature of every native function registered so far, in registration order.
static RECORDS: Mutex<Vec<LuauFnRecord>> = Mutex::new(Vec::new());

/// Gives a Rust value type the Luau type text a type file writes for it.
pub trait LuauType {
    /// Returns the Luau type text of `Self`.
    fn luau_type() -> String;
}

/// Gives a native function's Rust return type the Luau text of what Luau receives.
pub trait LuauReturn {
    /// Returns the Luau return type text of `Self`.
    fn luau_return() -> String;
}

impl<T> LuauReturn for mlua::Result<T>
where
    T: LuauType,
{
    fn luau_return() -> String {
        T::luau_type()
    }
}

/// Implements [`LuauType`] for types that share one fixed Luau text.
macro_rules! luau_fixed {
    ($text:literal: $($ty:ty),+) => {
        $(
            impl LuauType for $ty {
                fn luau_type() -> String {
                    $text.to_owned()
                }
            }
        )+
    };
}

luau_fixed!("string": String, LuaString);
luau_fixed!("number": i32, i64, u8, u16, u32, u64, usize, f32, f64);
luau_fixed!("boolean": bool);
luau_fixed!("any": Value);
luau_fixed!("...any": MultiValue);
luau_fixed!("{ [any]: any }": Table);
luau_fixed!("(...any) -> ...any": Function);
luau_fixed!("userdata": AnyUserData);
luau_fixed!("()": ());

impl<T> LuauType for Option<T>
where
    T: LuauType,
{
    fn luau_type() -> String {
        format!("{}?", grouped(T::luau_type()))
    }
}

impl<T> LuauType for Vec<T>
where
    T: LuauType,
{
    fn luau_type() -> String {
        format!("{{ {} }}", T::luau_type())
    }
}

impl<T> LuauType for Variadic<T>
where
    T: LuauType,
{
    fn luau_type() -> String {
        format!("...{}", grouped(T::luau_type()))
    }
}

impl<K, V> LuauType for HashMap<K, V>
where
    K: LuauType,
    V: LuauType,
{
    fn luau_type() -> String {
        format!("{{ [{}]: {} }}", K::luau_type(), V::luau_type())
    }
}

impl<K, V> LuauType for BTreeMap<K, V>
where
    K: LuauType,
    V: LuauType,
{
    fn luau_type() -> String {
        format!("{{ [{}]: {} }}", K::luau_type(), V::luau_type())
    }
}

/// A `Result` crosses as the value alone, or as `nil` and the reason.
impl<T, E> LuauType for StdResult<T, E>
where
    T: LuauType,
    E: LuauType,
{
    fn luau_type() -> String {
        let value = T::luau_type();
        let value = if value == "()" {
            "nil".to_owned()
        } else {
            format!("{}?", grouped(value))
        };
        format!("({value}, {}?)", grouped(E::luau_type()))
    }
}

/// Implements [`LuauType`] for a tuple, the Rust form of several return values.
macro_rules! luau_tuple {
    ($($name:ident),+) => {
        impl<$($name),+> LuauType for ($($name,)+)
        where
            $($name: LuauType,)+
        {
            fn luau_type() -> String {
                let parts: Vec<String> = vec![$($name::luau_type()),+];
                format!("({})", parts.join(", "))
            }
        }
    };
}

luau_tuple!(A);
luau_tuple!(A, B);
luau_tuple!(A, B, C);
luau_tuple!(A, B, C, D);

/// Wraps a union or function type in parentheses so a suffix such as `?` binds to all of it.
#[must_use]
fn grouped(text: String) -> String {
    let compound = !text.starts_with('{') && (text.contains('|') || text.contains("->"));
    if compound { format!("({text})") } else { text }
}

/// Signature of one registered native function, as a type file writes it.
#[derive(Clone, Debug)]
pub struct LuauFnRecord {
    /// Module name under `dev`, such as `os`.
    pub module: &'static str,
    /// Function name inside the module.
    pub name: &'static str,
    /// Parameter names beside their Luau types, in order.
    pub params: Vec<(&'static str, String)>,
    /// Luau text of the return type.
    pub returns: String,
    /// Doc comment lines, trimmed.
    pub docs: Vec<&'static str>,
    /// Hand-written signature that replaces the derived one, or the type of a value member.
    pub luau: Option<String>,
    /// Whether this records a non-function member, whose `luau` is then its type.
    pub value: bool,
}

impl LuauFnRecord {
    /// Returns the Luau function type, the override when one is given, or a member's type.
    #[must_use]
    pub fn signature(&self) -> String {
        if let Some(text) = &self.luau {
            return text.clone();
        }
        let params: Vec<String> = self
            .params
            .iter()
            .map(|(name, ty)| match ty.strip_prefix("...") {
                Some(rest) => format!("...{rest}"),
                None => format!("{name}: {ty}"),
            })
            .collect();
        format!("({}) -> {}", params.join(", "), self.returns)
    }
}

/// Adds one registered function's signature to the list the type files are written from.
pub fn record(record: LuauFnRecord) {
    RECORDS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(record);
}

/// Adds a non-function member of a native module, or a field of a handle type, to the list.
///
/// `luau_type` is the member's Luau type. A member recorded again under the same module and
/// name replaces the earlier one, so a table built on every call is listed once.
pub fn value(module: &'static str, name: &'static str, luau_type: String, doc: &'static str) {
    let member = LuauFnRecord {
        module,
        name,
        params: Vec::new(),
        returns: String::new(),
        docs: vec![doc],
        luau: Some(luau_type),
        value: true,
    };
    let mut records = RECORDS.lock().unwrap_or_else(PoisonError::into_inner);
    let same =
        |record: &LuauFnRecord| record.value && record.module == module && record.name == name;
    match records.iter_mut().find(|record| same(record)) {
        Some(slot) => *slot = member,
        None => records.push(member),
    }
}

/// Returns the Luau table type of a table of string constants, each key at its literal value.
#[must_use]
pub fn constants<'a>(pairs: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    let fields: Vec<String> = pairs
        .into_iter()
        .map(|(key, text)| format!("{key}: {text:?}"))
        .collect();
    format!("{{ {} }}", fields.join(", "))
}

/// Returns the signature of every native function registered so far.
#[must_use]
pub fn records() -> Vec<LuauFnRecord> {
    RECORDS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// Expands to `Some(text)` when an override string is given and `None` otherwise.
#[doc(hidden)]
#[macro_export]
macro_rules! luau_override {
    () => {
        None
    };
    ($text:literal) => {
        Some($text)
    };
}

/// Expands to the name a native function registers under: the override, else its Rust name.
#[doc(hidden)]
#[macro_export]
macro_rules! luau_name {
    (; $name:ident) => {
        stringify!($name)
    };
    ($text:literal; $name:ident) => {
        $text
    };
}

/// Gives a userdata handle type the Luau type name its methods are declared under.
///
/// `luau_handle!(LockHandle, "Lock")` makes a parameter or return of `LockHandle` read `Lock`
/// in a signature. The module's type file declares `export type Lock` with the methods.
#[macro_export]
macro_rules! luau_handle {
    ($ty:ty, $text:literal) => {
        impl $crate::luau::LuauType for $ty {
            fn luau_type() -> String {
                $text.to_owned()
            }
        }
    };
}

/// Defines a native function and a same-named module holding its registration.
///
/// The function's first parameter is `&Lua`. Its return type is an `mlua::Result`, raised in
/// Luau as an error, around the value Luau receives. A `StdResult<T, String>` inside it reaches
/// Luau as `value` or `nil, reason`. `#[luau = "..."]` after the doc comment replaces the
/// derived signature, and `#[name = "..."]` after that registers the function under another
/// name, such as `move` for `move_path`. `NAME::register(lua, module, table)` sets the function
/// on `table` and records its signature.
#[macro_export]
macro_rules! native_fn {
    (
        $(#[doc = $doc:literal])*
        $(#[luau = $luau:literal])?
        $(#[name = $lname:literal])?
        pub fn $name:ident($lua:ident: &Lua $(, $arg:ident: $ty:ty)* $(,)?) -> $ret:ty $body:block
    ) => {
        $(#[doc = $doc])*
        pub fn $name($lua: &::mlua::Lua $(, $arg: $ty)*) -> $ret $body

        #[doc = concat!("Registration of [`", stringify!($name), "`].")]
        pub mod $name {
            use super::*;

            /// Sets the function on `table` and records its signature under `module`.
            ///
            /// # Errors
            ///
            /// Returns the Lua error when the function cannot be created or set.
            pub fn register(
                lua: &::mlua::Lua,
                module: &'static str,
                table: &::mlua::Table,
            ) -> ::mlua::Result<()> {
                let function = lua.create_function(move |lua, ($($arg,)*): ($($ty,)*)| {
                    $crate::log::native_call(module, $crate::luau_name!($($lname)?; $name));
                    $name(lua $(, $arg)*)
                })?;
                table.set($crate::luau_name!($($lname)?; $name), function)?;
                $crate::luau::record(record(module));
                Ok(())
            }

            /// Returns the function's signature as registered under `module`.
            #[must_use]
            pub fn record(module: &'static str) -> $crate::luau::LuauFnRecord {
                $crate::luau::LuauFnRecord {
                    module,
                    name: $crate::luau_name!($($lname)?; $name),
                    params: vec![
                        $((stringify!($arg), <$ty as $crate::luau::LuauType>::luau_type()),)*
                    ],
                    returns: <$ret as $crate::luau::LuauReturn>::luau_return(),
                    docs: vec![$($doc.trim(),)*],
                    luau: $crate::luau_override!($($luau)?).map(str::to_owned),
                    value: false,
                }
            }
        }
    };
}

/// Defines a struct that crosses into Luau as a plain table, with its conversions and shape.
///
/// Every field is `pub`. A missing field reads as `nil`, so an `Option` field is optional in
/// Luau and any other field is required. `#[luau = "..."]` after the doc comment replaces the
/// derived table shape.
#[macro_export]
macro_rules! native_struct {
    (
        $(#[doc = $doc:literal])*
        $(#[luau = $luau:literal])?
        pub struct $name:ident {
            $($(#[doc = $fdoc:literal])* pub $field:ident: $fty:ty),* $(,)?
        }
    ) => {
        $(#[doc = $doc])*
        #[derive(Clone, Debug)]
        pub struct $name {
            $($(#[doc = $fdoc])* pub $field: $fty,)*
        }

        impl ::mlua::FromLua for $name {
            fn from_lua(value: ::mlua::Value, _lua: &::mlua::Lua) -> ::mlua::Result<Self> {
                let table = match value {
                    ::mlua::Value::Table(table) => table,
                    other => {
                        return Err(::mlua::Error::FromLuaConversionError {
                            from: other.type_name(),
                            to: stringify!($name).to_owned(),
                            message: Some("expected a table".to_owned()),
                        });
                    }
                };
                Ok(Self {
                    $($field: table.get(stringify!($field)).map_err(|error: ::mlua::Error| {
                        ::mlua::ErrorContext::context(
                            error,
                            concat!("field `", stringify!($field), "` of ", stringify!($name)),
                        )
                    })?,)*
                })
            }
        }

        impl ::mlua::IntoLua for $name {
            fn into_lua(self, lua: &::mlua::Lua) -> ::mlua::Result<::mlua::Value> {
                let table = lua.create_table()?;
                $(table.set(stringify!($field), self.$field)?;)*
                Ok(::mlua::Value::Table(table))
            }
        }

        impl $crate::luau::LuauType for $name {
            fn luau_type() -> String {
                let text: Option<&str> = $crate::luau_override!($($luau)?);
                text.map_or_else(
                    || {
                        let fields: Vec<String> = vec![$(format!(
                            "{}: {}",
                            stringify!($field),
                            <$fty as $crate::luau::LuauType>::luau_type(),
                        ),)*];
                        format!("{{ {} }}", fields.join(", "))
                    },
                    |text| text.to_owned(),
                )
            }
        }
    };
}

/// Defines a fieldless enum that crosses into Luau as one of a fixed set of strings.
#[macro_export]
macro_rules! native_enum {
    (
        $(#[doc = $doc:literal])*
        pub enum $name:ident {
            $($(#[doc = $vdoc:literal])* $variant:ident = $text:literal),+ $(,)?
        }
    ) => {
        $(#[doc = $doc])*
        #[derive(Copy, Clone, Debug, PartialEq, Eq)]
        pub enum $name {
            $($(#[doc = $vdoc])* $variant,)+
        }

        impl $name {
            /// Returns the string Luau sees for this value.
            #[must_use]
            pub fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $text,)+
                }
            }
        }

        impl ::mlua::FromLua for $name {
            fn from_lua(value: ::mlua::Value, lua: &::mlua::Lua) -> ::mlua::Result<Self> {
                let text = <::mlua::LuaString as ::mlua::FromLua>::from_lua(value, lua)?;
                let text = text.to_str()?;
                match &*text {
                    $($text => Ok(Self::$variant),)+
                    other => Err(::mlua::Error::FromLuaConversionError {
                        from: "string",
                        to: stringify!($name).to_owned(),
                        message: Some(format!(
                            "expected one of {}, got `{other}`",
                            <Self as $crate::luau::LuauType>::luau_type(),
                        )),
                    }),
                }
            }
        }

        impl ::mlua::IntoLua for $name {
            fn into_lua(self, lua: &::mlua::Lua) -> ::mlua::Result<::mlua::Value> {
                lua.create_string(self.as_str()).map(::mlua::Value::String)
            }
        }

        impl $crate::luau::LuauType for $name {
            fn luau_type() -> String {
                let texts: Vec<String> = vec![$(format!("{:?}", $text),)+];
                texts.join(" | ")
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use mlua::Lua;

    use super::*;

    native_fn! {
        /// Joins `word` to itself `times` times.
        pub fn echo(_lua: &Lua, word: String, times: Option<i64>) -> mlua::Result<String> {
            Ok(word.repeat(usize::try_from(times.unwrap_or(2)).unwrap_or(0)))
        }
    }

    native_fn! {
        /// Returns the length of `text`, or `nil` and a reason for an empty one.
        pub fn measure(_lua: &Lua, text: String) -> mlua::Result<StdResult<i64, String>> {
            if text.is_empty() {
                return Ok(Err("the text is empty".to_owned()));
            }
            Ok(Ok(i64::try_from(text.len()).unwrap_or(i64::MAX)))
        }
    }

    native_fn! {
        /// Calls `callback` with each word.
        #[luau = "(callback: (string) -> (), ...string) -> ()"]
        pub fn each(_lua: &Lua, callback: Function, words: Variadic<String>) -> mlua::Result<()> {
            for word in words {
                callback.call::<()>(word)?;
            }
            Ok(())
        }
    }

    native_enum! {
        /// Kind of a filesystem entry.
        pub enum Kind {
            /// A regular file.
            File = "file",
            /// A directory.
            Dir = "dir",
        }
    }

    native_struct! {
        /// One entry of a listing.
        pub struct Entry {
            /// Name of the entry.
            pub name: String,
            /// Kind of the entry.
            pub kind: Kind,
            /// Size in bytes, absent for a directory.
            pub size: Option<i64>,
            /// Tags on the entry.
            pub tags: Vec<String>,
        }
    }

    native_struct! {
        /// A table whose keys are open.
        #[luau = "{ [string]: any }"]
        pub struct Open {
            /// The one field Rust reads.
            pub name: String,
        }
    }

    native_fn! {
        /// Returns `entry` with its size doubled.
        pub fn grow(_lua: &Lua, entry: Entry) -> mlua::Result<Entry> {
            Ok(Entry { size: entry.size.map(|size| size * 2), ..entry })
        }
    }

    /// A handle to Rust-owned state.
    pub struct Counter;

    impl mlua::UserData for Counter {}

    luau_handle!(Counter, "Counter");

    native_fn! {
        /// Returns a new counter handle.
        #[name = "new"]
        pub fn new_counter(_lua: &Lua) -> mlua::Result<Counter> {
            Ok(Counter)
        }
    }

    fn module(lua: &Lua) -> Table {
        let table = lua.create_table().unwrap();
        new_counter::register(lua, "test", &table).unwrap();
        echo::register(lua, "test", &table).unwrap();
        measure::register(lua, "test", &table).unwrap();
        each::register(lua, "test", &table).unwrap();
        grow::register(lua, "test", &table).unwrap();
        lua.globals().set("test", table.clone()).unwrap();
        table
    }

    #[test]
    fn native_fn_should_register_a_callable_function() {
        let lua = Lua::new();
        module(&lua);
        let text: String = lua.load(r#"return test.echo("ab", 3)"#).eval().unwrap();
        assert_eq!(text, "ababab");
        let text: String = lua.load(r#"return test.echo("ab")"#).eval().unwrap();
        assert_eq!(text, "abab");
    }

    #[test]
    fn native_fn_should_return_nil_and_a_reason_for_an_expected_failure() {
        let lua = Lua::new();
        module(&lua);
        let (value, reason): (Option<i64>, Option<String>) =
            lua.load(r#"return test.measure("")"#).eval().unwrap();
        assert_eq!(value, None);
        assert_eq!(reason.as_deref(), Some("the text is empty"));
        let (value, reason): (Option<i64>, Option<String>) =
            lua.load(r#"return test.measure("abc")"#).eval().unwrap();
        assert_eq!(value, Some(3));
        assert_eq!(reason, None);
    }

    #[test]
    fn native_fn_should_raise_on_a_wrong_argument_type() {
        let lua = Lua::new();
        module(&lua);
        let error = lua.load(r"return test.echo({})").exec().unwrap_err();
        assert!(error.to_string().contains("bad argument #1"), "{error}");
    }

    #[test]
    fn native_fn_should_record_names_types_and_docs() {
        let record = echo::record("test");
        assert_eq!(record.name, "echo");
        assert_eq!(record.docs, vec!["Joins `word` to itself `times` times."]);
        assert_eq!(
            record.signature(),
            "(word: string, times: number?) -> string"
        );
        assert_eq!(
            measure::record("test").signature(),
            "(text: string) -> (number?, string?)"
        );
        assert_eq!(grow::record("test").returns, Entry::luau_type());
    }

    #[test]
    fn native_fn_should_use_the_override_for_a_callback() {
        let record = each::record("test");
        assert_eq!(
            record.signature(),
            "(callback: (string) -> (), ...string) -> ()"
        );
        assert_eq!(record.params[1], ("words", "...string".to_owned()));
        let lua = Lua::new();
        module(&lua);
        let joined: String = lua
            .load(
                r#"
                local out = {}
                test.each(function(word) table.insert(out, word) end, "a", "b")
                return table.concat(out, ",")
                "#,
            )
            .eval()
            .unwrap();
        assert_eq!(joined, "a,b");
    }

    #[test]
    fn native_fn_should_register_under_the_name_override_with_the_handle_type() {
        let record = new_counter::record("test");
        assert_eq!(record.name, "new");
        assert_eq!(record.signature(), "() -> Counter");
        let lua = Lua::new();
        module(&lua);
        let kind: String = lua.load("return type(test.new())").eval().unwrap();
        assert_eq!(kind, "userdata");
        let missing: Value = lua.load("return test.new_counter").eval().unwrap();
        assert!(missing.is_nil());
    }

    #[test]
    fn native_fn_should_add_its_record_on_register() {
        let lua = Lua::new();
        module(&lua);
        let found = records()
            .iter()
            .any(|record| record.module == "test" && record.name == "grow");
        assert!(found);
    }

    #[test]
    fn value_should_record_a_member_with_its_type_and_replace_a_repeat() {
        value("valuetest", "limit", "number".to_owned(), "Largest size.");
        value("valuetest", "limit", "number?".to_owned(), "Largest size.");
        let found: Vec<LuauFnRecord> = records()
            .into_iter()
            .filter(|record| record.module == "valuetest")
            .collect();
        assert_eq!(found.len(), 1);
        assert!(found[0].value);
        assert!(found[0].params.is_empty());
        assert_eq!(found[0].signature(), "number?");
        assert_eq!(found[0].docs, vec!["Largest size."]);
        assert!(!echo::record("test").value);
    }

    #[test]
    fn constants_should_type_each_key_at_its_literal() {
        assert_eq!(
            constants([("UP", "up"), ("CTRL_C", "ctrl-c")]),
            r#"{ UP: "up", CTRL_C: "ctrl-c" }"#
        );
    }

    #[test]
    fn native_struct_should_round_trip_through_luau() {
        let lua = Lua::new();
        module(&lua);
        let entry: Entry = lua
            .load(
                r#"return test.grow({ name = "a.txt", kind = "file", size = 4, tags = { "x" } })"#,
            )
            .eval()
            .unwrap();
        assert_eq!(entry.name, "a.txt");
        assert_eq!(entry.kind, Kind::File);
        assert_eq!(entry.size, Some(8));
        assert_eq!(entry.tags, vec!["x".to_owned()]);
        let same: bool = lua
            .load(
                r#"
                local entry = test.grow({ name = "d", kind = "dir", tags = {} })
                return entry.name == "d" and entry.kind == "dir" and entry.size == nil
                "#,
            )
            .eval()
            .unwrap();
        assert!(same);
    }

    #[test]
    fn native_struct_should_return_the_fields_its_shape_records() {
        // Return an entry from Luau as a raw table
        let lua = Lua::new();
        module(&lua);
        let table: mlua::Table = lua
            .load(
                r#"return test.grow({ name = "a.txt", kind = "file", size = 4, tags = { "x" } })"#,
            )
            .eval()
            .unwrap();
        // Split the recorded shape into name and type pairs
        let shape = Entry::luau_type();
        let inner = shape
            .strip_prefix("{ ")
            .and_then(|rest| rest.strip_suffix(" }"))
            .expect("shape is a braced record");
        let fields: Vec<(&str, &str)> = inner
            .split(", ")
            .map(|field| field.split_once(": ").expect("field is name: type"))
            .collect();
        assert_eq!(table.pairs::<String, mlua::Value>().count(), fields.len());
        // Check each field's Luau type against the recorded one
        for (name, luau_type) in fields {
            let balanced = |open: char, close: char| {
                luau_type.matches(open).count() == luau_type.matches(close).count()
            };
            assert!(
                balanced('{', '}') && balanced('(', ')'),
                "field {name} has a type this splitter cannot read: {luau_type}"
            );
            let expected = match luau_type.trim_end_matches('?') {
                kind if kind.starts_with('{') => "table",
                kind if kind.starts_with('"') => "string",
                kind => kind,
            };
            let value: mlua::Value = table.get(name).unwrap();
            let actual = match value {
                mlua::Value::Integer(_) | mlua::Value::Number(_) => "number",
                other => other.type_name(),
            };
            assert_eq!(actual, expected, "field {name}");
        }
    }

    #[test]
    fn native_struct_should_record_its_shape() {
        assert_eq!(
            Entry::luau_type(),
            r#"{ name: string, kind: "file" | "dir", size: number?, tags: { string } }"#
        );
        assert_eq!(Open::luau_type(), "{ [string]: any }");
    }

    #[test]
    fn native_struct_should_name_a_missing_required_field() {
        let lua = Lua::new();
        module(&lua);
        let error = lua
            .load(r#"return test.grow({ kind = "file", tags = {} })"#)
            .exec()
            .unwrap_err();
        assert!(
            error.to_string().contains("field `name` of Entry"),
            "{error}"
        );
    }

    #[test]
    fn native_enum_should_refuse_an_unknown_string() {
        let lua = Lua::new();
        module(&lua);
        let error = lua
            .load(r#"return test.grow({ name = "a", kind = "pipe", tags = {} })"#)
            .exec()
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains(r#"expected one of "file" | "dir", got `pipe`"#),
            "{error}"
        );
    }

    #[test]
    fn luau_type_should_group_a_union_before_a_suffix() {
        assert_eq!(Option::<Kind>::luau_type(), r#"("file" | "dir")?"#);
        assert_eq!(Option::<Function>::luau_type(), "((...any) -> ...any)?");
        assert_eq!(StdResult::<(), String>::luau_type(), "(nil, string?)");
    }
}

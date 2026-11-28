use std::path::{Path, PathBuf};
use std::{env, fs};

use syn::visit::{self, Visit};
use syn::{ExprMethodCall, ImplItemFn, ItemFn};

/// Methods of `mlua::Lua` that make a native function.
const CREATORS: [&str; 3] = [
    "create_function",
    "create_function_mut",
    "create_async_function",
];

/// Name a creator call gets when it sits outside every function.
const OUTSIDE_FN: &str = "<module>";

/// Internal closures that are not module functions, as `(file, enclosing function, reason)`.
const ALLOWED: [(&str, &str, &str); 5] = [
    (
        "src/runtime.rs",
        "new",
        "the `require` and `print` globals are script entry points, not a module's functions",
    ),
    (
        "src/runtime.rs",
        "trace_module_calls",
        "the logging hook of the module-call wrapper is not a function a script calls",
    ),
    (
        "src/native/json.rs",
        "register",
        "`json.null`'s `__tostring` is a metamethod on a sentinel, not a module function",
    ),
    (
        "src/native/term.rs",
        "once",
        "the run-once wrapper around an `exit` cleanup is internal",
    ),
    (
        "src/native/term.rs",
        "register",
        "the terminal restore cleanup handed to `exit` is internal",
    ),
];

/// A creator call found outside a `native_fn!` invocation.
#[derive(Debug, PartialEq, Eq)]
struct Finding {
    file: String,
    function: String,
}

impl Finding {
    #[must_use]
    fn describe(&self) -> String {
        format!("{}: {}", self.file, self.function)
    }

    #[must_use]
    fn is_in(&self, file: &str, function: &str) -> bool {
        self.file == file && self.function == function
    }
}

/// Collects creator calls, tracking the function that holds each.
///
/// `syn` leaves a macro invocation as opaque tokens, so nothing inside `native_fn!` or a
/// `macro_rules!` definition is visited.
struct Scanner<'a> {
    file: &'a str,
    functions: Vec<String>,
    found: Vec<Finding>,
}

impl Visit<'_> for Scanner<'_> {
    fn visit_item_fn(&mut self, node: &ItemFn) {
        self.functions.push(node.sig.ident.to_string());
        visit::visit_item_fn(self, node);
        self.functions.pop();
    }

    fn visit_impl_item_fn(&mut self, node: &ImplItemFn) {
        self.functions.push(node.sig.ident.to_string());
        visit::visit_impl_item_fn(self, node);
        self.functions.pop();
    }

    fn visit_expr_method_call(&mut self, node: &ExprMethodCall) {
        if CREATORS.contains(&node.method.to_string().as_str()) {
            let function = self
                .functions
                .last()
                .map_or(OUTSIDE_FN, String::as_str)
                .to_owned();
            self.found.push(Finding {
                file: self.file.to_owned(),
                function,
            });
        }
        visit::visit_expr_method_call(self, node);
    }
}

/// Finds the creator calls in `source`, a file shown as `file`, that no `native_fn!` holds.
#[must_use]
fn scan(file: &str, source: &str) -> Vec<Finding> {
    let syntax = syn::parse_file(source)
        .unwrap_or_else(|error| panic!("{file} should parse as Rust: {error}"));
    let mut scanner = Scanner {
        file,
        functions: Vec::new(),
        found: Vec::new(),
    };
    scanner.visit_file(&syntax);
    scanner.found
}

/// Lists the `.rs` files under `dir`, sorted.
#[must_use]
fn rust_files(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .expect("the source directory should be readable")
        .map(|entry| entry.expect("a directory entry should be readable").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            files.extend(rust_files(&path));
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            files.push(path);
        }
    }
    files
}

#[must_use]
fn is_allowed(finding: &Finding) -> bool {
    ALLOWED
        .iter()
        .any(|(file, function, _)| finding.is_in(file, function))
}

#[test]
fn scan_should_name_the_file_and_function_of_a_creator_call_outside_native_fn() {
    let source = r#"
        pub fn register(lua: &Lua) -> mlua::Result<Table> {
            let table = lua.create_table()?;
            table.set("a", lua.create_function(|_, ()| Ok(()))?)?;
            table.set("b", lua.create_function_mut(|_, ()| Ok(()))?)?;
            Ok(table)
        }

        impl Holder {
            fn build(lua: &Lua) {
                lua.create_async_function(|_, ()| async { Ok(()) });
            }
        }
    "#;

    let found: Vec<String> = scan("src/fake.rs", source)
        .iter()
        .map(Finding::describe)
        .collect();

    assert_eq!(
        found,
        [
            "src/fake.rs: register",
            "src/fake.rs: register",
            "src/fake.rs: build"
        ]
    );
}

#[test]
fn scan_should_skip_a_creator_call_inside_native_fn() {
    let source = r#"
        native_fn! {
            /// Adds.
            pub fn add(lua: &Lua, a: i64) -> mlua::Result<Function> {
                lua.create_function(move |_, ()| Ok(a))
            }
        }
    "#;

    assert_eq!(scan("src/fake.rs", source), []);
}

#[test]
fn scan_should_report_a_creator_call_outside_every_function() {
    let source = "static F: fn() = || { Lua::new().create_function(|_, ()| Ok(())); };";

    assert_eq!(
        scan("src/fake.rs", source),
        [Finding {
            file: "src/fake.rs".to_owned(),
            function: OUTSIDE_FN.to_owned(),
        }]
    );
}

#[test]
fn every_native_function_in_src_should_go_through_native_fn_or_the_allowlist() {
    // Scan every source file under src
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut found = Vec::new();
    for path in rust_files(&root.join("src")) {
        let source = fs::read_to_string(&path).expect("a source file should be readable");
        let relative = path
            .strip_prefix(root)
            .expect("a source file should sit under the crate root")
            .to_string_lossy()
            .replace('\\', "/");
        found.extend(scan(&relative, &source));
    }

    // Every creator call must be allowlisted
    let unregistered: Vec<String> = found
        .iter()
        .filter(|finding| !is_allowed(finding))
        .map(Finding::describe)
        .collect();
    assert!(
        unregistered.is_empty(),
        "native functions created outside native_fn!, which records their signature: {unregistered:?}"
    );

    // Every allowlist entry must still match a call
    let stale: Vec<String> = ALLOWED
        .iter()
        .filter(|(file, function, _)| !found.iter().any(|finding| finding.is_in(file, function)))
        .map(|(file, function, _)| format!("{file}: {function}"))
        .collect();
    assert!(
        stale.is_empty(),
        "allowlist entries that match no creator call: {stale:?}"
    );
}

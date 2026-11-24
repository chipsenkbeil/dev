use include_dir::{Dir, include_dir};

/// dev's Luau modules, as `luau/dev/**` reads them.
static LUAU: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/luau");

/// The topic docs, as `docs/**` reads them.
static DOCS: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/docs");

/// The files `dev init` writes, as `init/**` reads them.
static INIT: Dir<'static> = include_dir!("$CARGO_MANIFEST_DIR/init");

/// Returns the embedded folder a top-level name such as `luau` stands for.
#[must_use]
fn root(name: &str) -> Option<&'static Dir<'static>> {
    match name {
        "luau" => Some(&LUAU),
        "docs" => Some(&DOCS),
        "init" => Some(&INIT),
        _ => None,
    }
}

/// Returns the bytes of the embedded file at `path`, such as `docs/flags.md`.
#[must_use]
pub fn file(path: &str) -> Option<&'static [u8]> {
    let (top, rest) = path.split_once('/')?;
    root(top)?.get_file(rest).map(|file| file.contents())
}

/// Returns the names of the files and folders directly inside the embedded folder at `path`,
/// sorted.
#[must_use]
pub fn entries(path: &str) -> Option<Vec<String>> {
    let path = path.trim_end_matches('/');
    let dir = match path.split_once('/') {
        Some((top, rest)) => root(top)?.get_dir(rest)?,
        None => root(path)?,
    };
    let mut names: Vec<String> = dir
        .entries()
        .iter()
        .filter_map(|entry| entry.path().file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .collect();
    names.sort();
    Some(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_should_read_an_embedded_doc() {
        let text = file("docs/flags.md").unwrap();
        assert!(!text.is_empty());
    }

    #[test]
    fn file_should_return_none_outside_the_three_roots() {
        assert!(file("src/main.rs").is_none());
        assert!(file("docs/missing.md").is_none());
        assert!(file("luau").is_none());
    }

    #[test]
    fn entries_should_list_a_folder_sorted() {
        let names = entries("luau/dev").unwrap();
        assert!(names.contains(&"cli.luau".to_owned()), "{names:?}");
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
        assert_eq!(entries("init"), entries("init/"));
    }
}

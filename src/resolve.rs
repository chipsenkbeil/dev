use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::{Error, Result};

/// Prefix of a require name served from the embedded tree.
pub const DEV_ALIAS: &str = "@dev/";

/// Name of the file that holds a folder's aliases.
const CONFIG_NAME: &str = ".luaurc";

/// Where a require name points before any file is probed.
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    /// A module of the embedded tree, named by the part after `@dev/`.
    Dev(String),
    /// A path on disk without its `.luau` suffix, for a file or a folder with an `init.luau`.
    Disk(PathBuf),
}

/// Resolves require `name` the way Luau's require-by-string does, from a file in folder `origin`.
///
/// `@dev/NAME` is built in, `./x` and `../x` are relative to `origin`, and any other `@alias/x`
/// goes through the nearest `.luaurc` at or above `origin` that defines the alias.
///
/// # Errors
///
/// Returns one sentence naming the Luau form to use for a dotted or bare name, and a sentence
/// naming the alias or the `.luaurc` when an alias does not resolve.
pub fn resolve(name: &str, origin: &Path) -> Result<Target> {
    if let Some(rest) = name.strip_prefix(DEV_ALIAS) {
        return Ok(Target::Dev(rest.to_owned()));
    }
    if name.starts_with("./") || name.starts_with("../") {
        return Ok(Target::Disk(origin.join(name)));
    }
    if let Some(alias) = name.strip_prefix('@') {
        let (alias, rest) = alias.split_once('/').unwrap_or((alias, ""));
        if alias == "dev" {
            return Err(Error::Message(format!(
                "The require name \"{name}\" names no module, so write \"@dev/NAME\"."
            )));
        }
        let base = alias_folder(alias, origin)?;
        return Ok(Target::Disk(base.join(rest)));
    }
    let path = name.replace('.', "/");
    Err(Error::Message(match name.strip_prefix("dev.") {
        Some(rest) => format!(
            "The require name \"{name}\" is the dotted form, so write \"@dev/{}\".",
            rest.replace('.', "/")
        ),
        None => format!(
            "The require name \"{name}\" is not a Luau path, so write \"./{path}\" for a file \
             beside this one, or \"@lib/{path}\" through a .luaurc alias."
        ),
    }))
}

/// Returns the folder `alias` stands for in the nearest `.luaurc` at or above `origin` that
/// defines it.
fn alias_folder(alias: &str, origin: &Path) -> Result<PathBuf> {
    for dir in origin.ancestors() {
        let config = dir.join(CONFIG_NAME);
        let Ok(text) = fs::read_to_string(&config) else {
            continue;
        };
        let parsed: Value = serde_json::from_str(&text).map_err(|error| {
            Error::Message(format!(
                "The file {} is not valid JSON: {error}.",
                config.display()
            ))
        })?;
        let target = parsed
            .get("aliases")
            .and_then(Value::as_object)
            .and_then(|aliases| {
                aliases
                    .iter()
                    .find(|(key, _)| key.eq_ignore_ascii_case(alias))
            })
            .and_then(|(_, value)| value.as_str());
        if let Some(target) = target {
            return Ok(dir.join(target));
        }
    }
    Err(Error::Message(format!(
        "No .luaurc at or above {} defines the alias \"@{alias}\".",
        origin.display()
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(label: &str, files: &[(&str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("dev-resolve-{}-{label}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (path, text) in files {
            let file = root.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, text).unwrap();
        }
        root
    }

    #[test]
    fn resolve_should_serve_a_dev_name_built_in() {
        let target = resolve("@dev/board/store", Path::new("/nowhere")).unwrap();
        assert_eq!(target, Target::Dev("board/store".to_owned()));
    }

    #[test]
    fn resolve_should_join_a_relative_name_to_the_origin() {
        let target = resolve("../x", Path::new("/a/b")).unwrap();
        assert_eq!(target, Target::Disk(PathBuf::from("/a/b/../x")));
    }

    #[test]
    fn resolve_should_refuse_a_dotted_dev_name_with_the_at_form() {
        let message = resolve("dev.board.store", Path::new("/a"))
            .unwrap_err()
            .to_string();
        assert!(message.contains("\"@dev/board/store\""), "{message}");
    }

    #[test]
    fn resolve_should_refuse_a_bare_name_with_the_relative_form() {
        let message = resolve("myproj.checks", Path::new("/a"))
            .unwrap_err()
            .to_string();
        assert!(message.contains("\"./myproj/checks\""), "{message}");
        assert!(message.contains("\"@lib/myproj/checks\""), "{message}");
    }

    #[test]
    fn resolve_should_use_the_nearest_luaurc_that_defines_the_alias() {
        let root = tree(
            "nearest",
            &[
                (".luaurc", r#"{"aliases":{"lib":"far"}}"#),
                ("a/.luaurc", r#"{"aliases":{"Lib":"near"}}"#),
                ("a/b/f.luau", ""),
            ],
        );
        let target = resolve("@lib/x", &root.join("a/b")).unwrap();
        assert_eq!(target, Target::Disk(root.join("a/near/x")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_should_inherit_an_alias_from_a_parent_luaurc() {
        let root = tree(
            "inherit",
            &[
                (".luaurc", r#"{"aliases":{"lib":"far"}}"#),
                ("a/.luaurc", r#"{"lint":{}}"#),
                ("a/f.luau", ""),
                ("x", ""),
            ],
        );
        let target = resolve("@lib/x", &root.join("a")).unwrap();
        assert_eq!(target, Target::Disk(root.join("far/x")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn resolve_should_name_an_alias_no_luaurc_defines() {
        let root = tree("missing", &[("a/f.luau", ""), ("b", "")]);
        let message = resolve("@nope/x", &root.join("a")).unwrap_err().to_string();
        assert!(message.contains("\"@nope\""), "{message}");
        let _ = fs::remove_dir_all(root);
    }
}

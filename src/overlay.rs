use std::collections::BTreeMap;
use std::env;
use std::process::Command;
use std::sync::{Mutex, PoisonError};

/// Variables dev sets (`Some`) or removes (`None`) for itself and every program it starts.
///
/// dev never writes its own process environment, which edition 2024 makes unsafe. Every read
/// goes through [`get`] or [`vars`] and every spawn through [`apply`].
static OVERLAY: Mutex<BTreeMap<String, Option<String>>> = Mutex::new(BTreeMap::new());

/// Sets variable `name` to `value`, or removes it when `value` is `None`.
pub fn set(name: &str, value: Option<&str>) {
    let mut overlay = OVERLAY.lock().unwrap_or_else(PoisonError::into_inner);
    overlay.insert(name.to_owned(), value.map(str::to_owned));
}

/// Returns the value of variable `name`, the overlay first and then dev's own environment.
#[must_use]
pub fn get(name: &str) -> Option<String> {
    let overlay = OVERLAY.lock().unwrap_or_else(PoisonError::into_inner);
    match overlay.get(name) {
        Some(value) => value.clone(),
        None => env::var(name).ok(),
    }
}

/// Returns every UTF-8 variable as a started program sees it, sorted by name.
#[must_use]
pub fn vars() -> BTreeMap<String, String> {
    let mut vars: BTreeMap<String, String> = env::vars_os()
        .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
        .collect();
    let overlay = OVERLAY.lock().unwrap_or_else(PoisonError::into_inner);
    for (name, value) in overlay.iter() {
        match value {
            Some(value) => vars.insert(name.clone(), value.clone()),
            None => vars.remove(name),
        };
    }
    vars
}

/// Gives `command` the overlay, so the program it starts sees what [`vars`] returns.
pub fn apply(command: &mut Command) {
    let overlay = OVERLAY.lock().unwrap_or_else(PoisonError::into_inner);
    for (name, value) in overlay.iter() {
        match value {
            Some(value) => command.env(name, value),
            None => command.env_remove(name),
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_should_shadow_and_remove_variables_for_reads_and_children() {
        set("DEV_OVERLAY_TEST_SET", Some("a b"));
        set("DEV_OVERLAY_TEST_GONE", None);
        assert_eq!(get("DEV_OVERLAY_TEST_SET").as_deref(), Some("a b"));
        assert_eq!(get("DEV_OVERLAY_TEST_GONE"), None);
        assert_eq!(get("PATH"), env::var("PATH").ok());
        let vars = vars();
        assert_eq!(
            vars.get("DEV_OVERLAY_TEST_SET").map(String::as_str),
            Some("a b")
        );
        assert!(!vars.contains_key("DEV_OVERLAY_TEST_GONE"));
        assert!(env::var("DEV_OVERLAY_TEST_SET").is_err());

        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            r#"printf '%s|%s' "$DEV_OVERLAY_TEST_SET" "${DEV_OVERLAY_TEST_GONE-unset}""#,
        ]);
        command.env("DEV_OVERLAY_TEST_GONE", "inherited");
        apply(&mut command);
        let output = command.output().expect("sh should run");
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a b|unset");
    }
}

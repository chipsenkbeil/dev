/// Folders the binary embeds, so a change inside one rebuilds it.
const EMBEDDED: [&str; 3] = ["luau", "docs", "init"];

/// Variable a release build sets to the tag it was made from.
const TAG_VAR: &str = "DEV_RELEASE_TAG";

fn main() {
    for dir in EMBEDDED {
        println!("cargo:rerun-if-changed={dir}");
    }
    println!("cargo:rerun-if-env-changed={TAG_VAR}");
    let tag = std::env::var(TAG_VAR).unwrap_or_default();
    let version = match tag.trim() {
        "" => std::env::var("CARGO_PKG_VERSION").unwrap_or_default(),
        tag => tag.to_owned(),
    };
    println!("cargo:rustc-env=DEV_VERSION={version}");
}

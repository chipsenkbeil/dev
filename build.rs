/// Folders the binary embeds, so a change inside one rebuilds it.
const EMBEDDED: [&str; 3] = ["luau", "docs", "init"];

fn main() {
    for dir in EMBEDDED {
        println!("cargo:rerun-if-changed={dir}");
    }
}

#![forbid(unsafe_code)]

/// Embedded Luau modules, docs and init files.
pub mod embed;
mod error;
/// dev's global flags, parsed before any Luau runs.
pub mod flags;
/// The verbosity, the log levels and the trace hooks behind `dev.log`.
pub mod log;
/// Luau type text for native values, and the macros native modules register through.
pub mod luau;
/// The one list that registers every native module.
pub mod modules;
/// The native modules under `dev.*`.
pub mod native;
/// The environment overlay dev and the programs it starts see.
pub mod overlay;
/// The require-by-string rule: relative paths, `.luaurc` aliases and the built-in `@dev`.
pub mod resolve;
/// The Luau state: `require`, chunks, output, interrupts, cleanups and exit.
pub mod runtime;

pub use error::{Error, Result};

/// `dev.fs`: files, folders and file descriptors.
pub mod fs;
/// `dev.globals`: the parsed global flags.
pub mod globals;
/// `dev.hash`: SHA-256 digests.
pub mod hash;
/// `dev.http`: HTTP requests and downloads.
pub mod http;
/// `dev.json`: JSON decoding and encoding.
pub mod json;
/// `dev.lock`: advisory file locks.
pub mod lock;
/// `dev.log`: leveled log lines on stderr.
pub mod log;
/// `dev.manifest`: the tools manifest parser.
pub mod manifest;
/// Permission bits across platforms, for `dev.fs` and `dev.lock`.
pub mod mode;
/// `dev.os`: the environment, processes, streams and exit.
pub mod os;
/// The built-in pager behind `dev.term.page`.
pub mod pager;
/// Spawning, waiting on and signalling processes for `dev.os`.
pub mod process;
/// `dev.runtime`: chunk loading, the module path and the embedded files.
pub mod runtime;
/// Signal handlers that turn a signal into a Luau interrupt.
pub mod signals;
/// `dev.spec`: command spec validation and argument parsing.
pub mod spec;
/// `dev.term`: the terminal.
pub mod term;
/// `dev.toml`: TOML parsing and editing.
pub mod toml;

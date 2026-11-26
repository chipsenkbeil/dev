use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use crate::native_enum;
use crate::runtime::write_err;

/// Highest verbosity, `-vvvv`.
pub const MAX_VERBOSITY: u8 = 4;

/// Verbosity from which every spawn is logged, `-vv`.
pub const SPAWN_VERBOSITY: u8 = 2;

/// Verbosity from which every native call is traced and `.sh` commands run under `bash -x`, `-vvv`.
pub const NATIVE_CALL_VERBOSITY: u8 = 3;

/// Verbosity from which calls between Luau modules are traced, `-vvvv`.
pub const MODULE_CALL_VERBOSITY: u8 = 4;

/// Values of `VERBOSE` that turn verbosity off.
const QUIET_VALUES: [&str; 3] = ["", "no", "false"];

/// Verbosity of the running dev, from 0 to [`MAX_VERBOSITY`].
static VERBOSITY: AtomicU8 = AtomicU8::new(0);

/// Whether `-q` asked for errors only.
static QUIET: AtomicBool = AtomicBool::new(false);

/// The verbosity words dev was started with, kept so a command can take some back.
static WORDS: Mutex<LogWords> = Mutex::new(LogWords::EMPTY);

native_enum! {
    /// Severity of a log line, from the most to the least severe.
    pub enum LogLevel {
        /// A failure, shown even under `-q`.
        Error = "error",
        /// Something likely wrong that did not stop dev.
        Warn = "warn",
        /// Progress shown by default.
        Info = "info",
        /// Detail shown from `-v`.
        Debug = "debug",
        /// Fine detail shown from `-vv`.
        Trace = "trace",
    }
}

impl LogLevel {
    /// Returns the level's rank, 0 for the most severe.
    #[must_use]
    pub fn rank(self) -> u8 {
        match self {
            Self::Error => 0,
            Self::Warn => 1,
            Self::Info => 2,
            Self::Debug => 3,
            Self::Trace => 4,
        }
    }

    /// Returns the text a line of this level starts with.
    #[must_use]
    pub fn prefix(self) -> &'static str {
        match self {
            Self::Error => "error: ",
            Self::Warn => "warning: ",
            Self::Info => "",
            Self::Debug => "debug: ",
            Self::Trace => "+ ",
        }
    }
}

/// The verbosity words of a command line and the `VERBOSE` value they fall back to.
#[derive(Debug)]
struct LogWords {
    /// Words before the first command word.
    leading: Vec<String>,
    /// Words stripped after the first command word, in order.
    stripped: Vec<String>,
    /// Value of `VERBOSE`.
    env: Option<String>,
}

impl LogWords {
    /// No words and no `VERBOSE`.
    const EMPTY: Self = Self {
        leading: Vec::new(),
        stripped: Vec::new(),
        env: None,
    };
}

/// Returns the verbosity a word adds and whether it asks for quiet, or `None` for any other word.
///
/// `-v`, `-vv` and longer runs add one per `v`, `--verbose` adds one, and `-q` or `--quiet` asks
/// for quiet.
#[must_use]
pub fn word_effect(word: &str) -> Option<(usize, bool)> {
    match word {
        "--verbose" => return Some((1, false)),
        "-q" | "--quiet" => return Some((0, true)),
        _ => {}
    }
    let letters = word.strip_prefix('-')?;
    let all_v = !letters.is_empty() && letters.bytes().all(|byte| byte == b'v');
    all_v.then_some((letters.len(), false))
}

/// Returns the verbosity and quiet that `words` ask for.
///
/// With no `-v` or `-q` word the verbosity is the `VERBOSE` value: a number, 1 for any other text, 0 for
/// empty, `no` or `false`. Both are capped at [`MAX_VERBOSITY`].
#[must_use]
pub fn verbosity_of<'a>(words: impl IntoIterator<Item = &'a str>, env: Option<&str>) -> (u8, bool) {
    let (mut count, mut quiet) = (0_usize, false);
    for (more, asks_quiet) in words.into_iter().filter_map(word_effect) {
        count = count.saturating_add(more);
        quiet |= asks_quiet;
    }
    let level = match (count, env) {
        (0, _) if quiet => 0,
        (0, None) => 0,
        (0, Some(value)) if QUIET_VALUES.contains(&value) => 0,
        (0, Some(value)) if !value.bytes().all(|byte| byte.is_ascii_digit()) => 1,
        (0, Some(value)) => value.parse::<usize>().unwrap_or(usize::MAX),
        (count, _) => count,
    };
    let capped = u8::try_from(level.min(usize::from(MAX_VERBOSITY))).unwrap_or(MAX_VERBOSITY);
    (capped, quiet)
}

/// Sets the verbosity from the command line's verbosity words and returns it with quiet.
pub fn start(leading: Vec<String>, stripped: Vec<String>, env: Option<String>) -> (u8, bool) {
    let mut words = WORDS.lock().unwrap_or_else(PoisonError::into_inner);
    *words = LogWords {
        leading,
        stripped,
        env,
    };
    take_effect(&words, &[])
}

/// Gives the stripped words at the 1-based `indexes` back to the command, and returns the
/// verbosity and quiet the remaining words ask for, which take effect at once.
pub fn retake(indexes: &[usize]) -> (u8, bool) {
    let words = WORDS.lock().unwrap_or_else(PoisonError::into_inner);
    take_effect(&words, indexes)
}

/// Sets and returns the verbosity and quiet that `words` ask for without the stripped words at
/// the 1-based `retaken` indexes.
fn take_effect(words: &LogWords, retaken: &[usize]) -> (u8, bool) {
    let kept = words
        .stripped
        .iter()
        .enumerate()
        .filter(|(index, _)| !retaken.contains(&(index + 1)))
        .map(|(_, word)| word);
    let all = words.leading.iter().chain(kept).map(String::as_str);
    let (level, quiet) = verbosity_of(all, words.env.as_deref());
    set_verbosity(level, quiet);
    (level, quiet)
}

/// Sets the verbosity, capped at [`MAX_VERBOSITY`], and whether only errors are shown.
pub fn set_verbosity(level: u8, quiet: bool) {
    VERBOSITY.store(level.min(MAX_VERBOSITY), Ordering::Relaxed);
    QUIET.store(quiet, Ordering::Relaxed);
}

/// Returns the verbosity, from 0 to [`MAX_VERBOSITY`].
#[must_use]
pub fn verbosity() -> u8 {
    VERBOSITY.load(Ordering::Relaxed)
}

/// Returns the least severe level shown: error under `-q`, info by default, debug at `-v` and
/// trace from `-vv`. A `-v` given with `-q` wins.
#[must_use]
pub fn threshold() -> LogLevel {
    match verbosity() {
        0 if QUIET.load(Ordering::Relaxed) => LogLevel::Error,
        0 => LogLevel::Info,
        1 => LogLevel::Debug,
        _ => LogLevel::Trace,
    }
}

/// Returns whether a line of `level` is shown.
#[must_use]
pub fn enabled(level: LogLevel) -> bool {
    level.rank() <= threshold().rank()
}

/// Writes `message` to stderr with the level's prefix when `level` is shown.
pub fn write(level: LogLevel, message: &str) {
    if enabled(level) {
        write_err(format!("{}{message}\n", level.prefix()).as_bytes());
    }
}

/// Returns whether each spawn is logged, from `-vv`.
#[must_use]
pub fn spawns() -> bool {
    verbosity() >= SPAWN_VERBOSITY
}

/// Logs one finished spawn: its words, folder, exit code (`None` when a signal ended it) and time.
pub fn spawn(argv: &[String], dir: &Path, code: Option<i32>, elapsed: Duration) {
    if !spawns() {
        return;
    }
    let words: Vec<String> = argv.iter().map(|word| quote(word)).collect();
    let end = code.map_or_else(|| "no exit code".to_owned(), |code| format!("exit {code}"));
    let line = format!(
        "({}) {}: {end} in {:.3}s",
        dir.display(),
        words.join(" "),
        elapsed.as_secs_f64(),
    );
    write(LogLevel::Trace, &line);
}

/// Returns whether `.sh` commands run under `bash -x`, from `-vvv`.
#[must_use]
pub fn xtrace() -> bool {
    verbosity() >= NATIVE_CALL_VERBOSITY
}

/// Traces a call of native function `dev.MODULE.NAME`, from `-vvv`.
///
/// A handle type's record module (`Process`, `Writer` or `Reader`) traces under the module that
/// owns the handle, as `os.proc` or `os.stream`.
pub fn native_call(module: &str, name: &str) {
    if verbosity() >= NATIVE_CALL_VERBOSITY {
        let module = match module {
            "Process" | "_exit" => "os.proc",
            "Writer" | "Reader" => "os.stream",
            other => other,
        };
        write_err(format!("+ dev.{module}.{name}\n").as_bytes());
    }
}

/// Returns whether calls between Luau modules are traced, from `-vvvv`.
#[must_use]
pub fn module_calls() -> bool {
    verbosity() >= MODULE_CALL_VERBOSITY
}

/// Traces a call of the Luau module function `name`, such as `dev.board.pomb.fetch`, from `-vvvv`.
pub fn module_call(name: &str) {
    if module_calls() {
        write_err(format!("+ {name}\n").as_bytes());
    }
}

/// Returns `word` as a shell would need it typed: bare when safe, else single-quoted.
#[must_use]
fn quote(word: &str) -> String {
    let safe = |byte: u8| byte.is_ascii_alphanumeric() || b"_./:=@%+,-".contains(&byte);
    if !word.is_empty() && word.bytes().all(safe) {
        return word.to_owned();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_effect_should_read_each_verbosity_word() {
        assert_eq!(word_effect("-v"), Some((1, false)));
        assert_eq!(word_effect("-vvv"), Some((3, false)));
        assert_eq!(word_effect("--verbose"), Some((1, false)));
        assert_eq!(word_effect("-q"), Some((0, true)));
        assert_eq!(word_effect("--quiet"), Some((0, true)));
        assert_eq!(word_effect("-vq"), None);
        assert_eq!(word_effect("-"), None);
        assert_eq!(word_effect("v"), None);
    }

    #[test]
    fn verbosity_of_should_count_words_and_fall_back_to_verbose() {
        assert_eq!(verbosity_of(["-v", "-vv"], None), (3, false));
        assert_eq!(verbosity_of(["-vvvvvv"], None), (MAX_VERBOSITY, false));
        assert_eq!(verbosity_of(["-q"], Some("2")), (0, true));
        assert_eq!(verbosity_of(["-v"], Some("4")), (1, false));
        assert_eq!(verbosity_of([], Some("3")), (3, false));
        assert_eq!(
            verbosity_of([], Some("99999999999999999999999")),
            (MAX_VERBOSITY, false)
        );
        assert_eq!(verbosity_of([], Some("yes")), (1, false));
        assert_eq!(verbosity_of([], Some("1.5")), (1, false));
        for quiet in ["", "no", "false", "0"] {
            assert_eq!(verbosity_of([], Some(quiet)), (0, false), "{quiet}");
        }
    }

    #[test]
    fn retake_should_count_only_the_stripped_words_the_command_left() {
        let words = |text: &str| text.split_whitespace().map(str::to_owned).collect();
        assert_eq!(start(words("-v"), words("-q -vv"), None), (3, true));
        assert_eq!(retake(&[2]), (1, true));
        assert_eq!(threshold(), LogLevel::Debug);
        assert_eq!(retake(&[1, 2]), (1, false));
        assert_eq!(retake(&[]), (3, true));
        assert_eq!(
            start(Vec::new(), words("-q"), Some("2".to_owned())),
            (0, true)
        );
        assert_eq!(threshold(), LogLevel::Error);
        assert_eq!(retake(&[1]), (2, false));
        assert_eq!(threshold(), LogLevel::Trace);
        set_verbosity(0, false);
    }

    #[test]
    fn quote_should_leave_safe_words_bare_and_quote_the_rest() {
        assert_eq!(quote("cargo"), "cargo");
        assert_eq!(quote("--x=a/b.c"), "--x=a/b.c");
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), r"'it'\''s'");
        assert_eq!(quote(""), "''");
    }

    #[test]
    fn level_rank_should_order_from_error_to_trace() {
        let levels = [
            LogLevel::Error,
            LogLevel::Warn,
            LogLevel::Info,
            LogLevel::Debug,
        ];
        for pair in levels.windows(2) {
            assert!(pair[0].rank() < pair[1].rank());
        }
        assert!(LogLevel::Debug.rank() < LogLevel::Trace.rank());
    }
}

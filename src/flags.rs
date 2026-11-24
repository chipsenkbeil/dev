use std::path::Path;
use std::{env, fmt};

use crate::{log, overlay, runtime};

/// Values of `DEV_REMOTE` that ask for a local run.
const LOCAL_VALUES: [&str; 3] = ["0", "no", "false"];

/// Words before the first command word that are not global flags but reach `dev.cli` as the
/// first command word, so `dev -h` still prints the help.
const COMMAND_FLAGS: [&str; 2] = ["-h", "--help"];

/// `PATH` dev runs with as root, so no user folder can shadow a system program.
const ROOT_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// Variables dev drops as root, since each can steer the shells and programs it starts.
const ROOT_UNSET: [&str; 4] = ["DEV_UID", "DEV_OS", "BASH_ENV", "ENV"];

/// What a global flag does, and so what it takes from the words after it.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum FlagsKind {
    /// `--remote`: run the command on ci.
    Remote,
    /// `--local`: run the command here.
    Local,
    /// `--detach`: start the remote run and return.
    Detach,
    /// `--priority`: start the remote run ahead of normal jobs.
    Priority,
    /// `--job-timeout [DURATION]`: bound the remote run, taking the next word unless it is a flag.
    JobTimeout,
    /// `-C DIR`: run as if dev started in `DIR`.
    Chdir,
    /// `--agent NAME`: export `DEV_AGENT`.
    Agent,
    /// `-l FILE ARGS`: run a Luau file with every word after it.
    Script,
    /// `-v` runs, `--verbose`, `-q` and `--quiet`, which also count after the first command word.
    Verbosity,
}

/// Every global flag by its word; a new global flag is one row here and one arm in [`parse`].
///
/// The `-v` runs are matched by [`log::word_effect`] rather than listed.
pub const GLOBALS: [(&str, FlagsKind); 11] = [
    ("--remote", FlagsKind::Remote),
    ("--local", FlagsKind::Local),
    ("--detach", FlagsKind::Detach),
    ("--priority", FlagsKind::Priority),
    ("--job-timeout", FlagsKind::JobTimeout),
    ("-C", FlagsKind::Chdir),
    ("--agent", FlagsKind::Agent),
    ("-l", FlagsKind::Script),
    ("--verbose", FlagsKind::Verbosity),
    ("-q", FlagsKind::Verbosity),
    ("--quiet", FlagsKind::Verbosity),
];

/// Returns the global flag `word` names, `-v` runs included.
#[must_use]
pub fn global(word: &str) -> Option<FlagsKind> {
    let row = GLOBALS
        .iter()
        .find(|(name, _)| *name == word)
        .map(|(_, kind)| *kind);
    row.or_else(|| log::word_effect(word).map(|_| FlagsKind::Verbosity))
}

/// The environment variables the global flags read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FlagsEnv {
    /// Value of `DEV_REMOTE`.
    pub remote: Option<String>,
    /// Value of `VERBOSE`.
    pub verbose: Option<String>,
}

impl FlagsEnv {
    /// Reads the variables from dev's environment, the overlay first.
    #[must_use]
    pub fn from_environment() -> Self {
        Self {
            remote: overlay::get("DEV_REMOTE"),
            verbose: overlay::get("VERBOSE"),
        }
    }
}

/// A Luau file `-l` runs, with the words after it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FlagsScript {
    /// Path of the file as given.
    pub path: String,
    /// Words after the file, in order.
    pub args: Vec<String>,
}

/// A verbosity word stripped from the command's words, and where it stood.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FlagsStripped {
    /// 1-based index in `args` the word stood before; `args.len() + 1` for a word at the end.
    pub at: usize,
    /// The word itself, such as `-vv` or `--quiet`.
    pub word: String,
}

/// dev's global flags, split from the command words before any Luau runs.
///
/// The fields up to `stripped` are the ones `dev.globals` carries, named as `dev.cli` reads them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "dev.globals carries these booleans by name"
)]
pub struct Flags {
    /// The command words and their arguments, with the first `--` and the verbosity words
    /// before it removed.
    pub args: Vec<String>,
    /// Number of words after the first `--`, 0 when none was typed.
    pub after: usize,
    /// Whether a `--` was typed, even with nothing after it.
    pub dashed: bool,
    /// Whether `--remote` or `DEV_REMOTE` asks for a remote run, and `--local` does not.
    pub remote: bool,
    /// Whether `--detach` was given.
    pub detach: bool,
    /// Whether `--priority` was given.
    pub priority: bool,
    /// The `--job-timeout` value, empty when the flag had none.
    pub job_timeout: Option<String>,
    /// Whether `--local` was given.
    pub local_flag: bool,
    /// Whether `DEV_REMOTE` says 0, no or false.
    pub env_local: bool,
    /// Whether `--local` and `--remote` were both given.
    pub conflict: bool,
    /// Verbosity, from 0 to [`log::MAX_VERBOSITY`].
    pub level: u8,
    /// Whether `-q` or `--quiet` was given.
    pub quiet: bool,
    /// Verbosity words taken from after the first command word, in order.
    pub stripped: Vec<FlagsStripped>,
    /// Verbosity words given before the first command word, in order.
    pub leading: Vec<String>,
    /// Value of `VERBOSE`, the fallback when no verbosity word was given.
    pub env_verbose: Option<String>,
    /// Folders `-C` names, in the order given.
    pub chdirs: Vec<String>,
    /// Name `--agent` gives.
    pub agent: Option<String>,
    /// File `-l` runs.
    pub script: Option<FlagsScript>,
}

impl Flags {
    /// Hands the verbosity words to the log, which sets the level and quiet they ask for.
    fn start_log(&self) {
        let stripped = self
            .stripped
            .iter()
            .map(|entry| entry.word.clone())
            .collect();
        log::start(self.leading.clone(), stripped, self.env_verbose.clone());
    }
}

/// A global flag that cannot be parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FlagsError {
    /// The `--agent` flag with no name.
    AgentNeedsName,
    /// The `-C` flag with no folder.
    ChdirNeedsDir,
    /// The `-l` flag with no file.
    ScriptNeedsFile,
    /// A word before the first command word that looks like a flag but is no global flag.
    Unknown(String),
    /// A `-C` folder that cannot be entered.
    CannotEnter(String),
}

impl fmt::Display for FlagsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AgentNeedsName => f.write_str("The --agent flag needs a name."),
            Self::ChdirNeedsDir => f.write_str("The flag `-C` needs a directory."),
            Self::ScriptNeedsFile => f.write_str("The flag `-l` needs a file."),
            Self::Unknown(word) => write!(f, "The flag `{word}` is not a global flag of dev."),
            Self::CannotEnter(dir) => write!(f, "The flag `-C` cannot enter {dir}."),
        }
    }
}

impl std::error::Error for FlagsError {}

/// Splits dev's global flags from `argv`, the words after the program name.
///
/// Global flags come before the first command word. That word and every word after it are the
/// command's, except the verbosity words before the first `--`, which are stripped into
/// `stripped`, and the first `--`, which is dropped and counted in `after`. A `--job-timeout`
/// takes the next word as its value unless it starts with `-`.
///
/// # Errors
///
/// Returns the flag that is missing its value, or a flag-like word that is no global flag.
pub fn parse(argv: Vec<String>, env: &FlagsEnv) -> Result<Flags, FlagsError> {
    let mut flags = Flags {
        env_verbose: env.verbose.clone(),
        ..Flags::default()
    };
    let mut remote_flag = false;
    let mut words = argv.into_iter().peekable();
    while let Some(word) = words.next_if(|word| is_flag(word)) {
        let Some(kind) = global(&word) else {
            return Err(FlagsError::Unknown(word));
        };
        match kind {
            FlagsKind::Remote => remote_flag = true,
            FlagsKind::Local => flags.local_flag = true,
            FlagsKind::Detach => flags.detach = true,
            FlagsKind::Priority => flags.priority = true,
            FlagsKind::JobTimeout => {
                let value = words.next_if(|value| !value.starts_with('-'));
                flags.job_timeout = Some(value.unwrap_or_default());
            }
            FlagsKind::Chdir => {
                let dir = words.next().filter(|dir| !dir.is_empty());
                flags.chdirs.push(dir.ok_or(FlagsError::ChdirNeedsDir)?);
            }
            FlagsKind::Agent => {
                let name = words.next().filter(|name| !name.is_empty());
                flags.agent = Some(name.ok_or(FlagsError::AgentNeedsName)?);
            }
            FlagsKind::Script => {
                let path = words.next().ok_or(FlagsError::ScriptNeedsFile)?;
                flags.script = Some(FlagsScript {
                    path,
                    args: words.by_ref().collect(),
                });
            }
            FlagsKind::Verbosity => flags.leading.push(word),
        }
    }

    // The rest belongs to the command, minus its verbosity words and its first `--`
    for word in words {
        if flags.dashed {
            flags.after += 1;
            flags.args.push(word);
        } else if word == "--" {
            flags.dashed = true;
        } else if log::word_effect(&word).is_some() {
            let at = flags.args.len() + 1;
            flags.stripped.push(FlagsStripped { at, word });
        } else {
            flags.args.push(word);
        }
    }

    let env_remote = env.remote.as_deref().unwrap_or_default();
    flags.env_local = LOCAL_VALUES.contains(&env_remote);
    let env_asks = !env_remote.is_empty() && !flags.env_local;
    flags.remote = (remote_flag || env_asks) && !flags.local_flag;
    flags.conflict = remote_flag && flags.local_flag;
    let stripped = flags.stripped.iter().map(|entry| entry.word.as_str());
    let all = flags.leading.iter().map(String::as_str).chain(stripped);
    (flags.level, flags.quiet) = log::verbosity_of(all, env.verbose.as_deref());
    Ok(flags)
}

/// Sets up the process the way the launcher did before Luau starts.
///
/// It enters each `-C` folder in turn. In the environment overlay that every started program
/// gets, it sets `PWD` to the end, `DEV_SELF` and the `--agent` name. As root it also resets
/// `PATH` and drops the variables that could steer a shell.
///
/// # Errors
///
/// Returns the first `-C` folder that cannot be entered.
pub fn apply(flags: &Flags) -> Result<(), FlagsError> {
    if runtime::is_root() {
        overlay::set("PATH", Some(ROOT_PATH));
        for name in ROOT_UNSET {
            overlay::set(name, None);
        }
    }
    if let Ok(exe) = env::current_exe().and_then(|path| path.canonicalize()) {
        overlay::set("DEV_SELF", Some(&exe.display().to_string()));
    }
    if let Some(agent) = &flags.agent {
        overlay::set("DEV_AGENT", Some(agent));
    }
    for dir in &flags.chdirs {
        env::set_current_dir(Path::new(dir)).map_err(|_| FlagsError::CannotEnter(dir.clone()))?;
    }
    if let Some(pwd) = env::current_dir().ok().filter(|_| !flags.chdirs.is_empty()) {
        overlay::set("PWD", Some(&pwd.display().to_string()));
    }
    Ok(())
}

/// Reads dev's command line the way the binary does: parses `argv`, applies the flags and hands
/// the verbosity words to the log.
///
/// # Errors
///
/// Returns the flag that cannot be parsed or the `-C` folder that cannot be entered.
pub fn load(argv: Vec<String>, env: &FlagsEnv) -> Result<Flags, FlagsError> {
    let flags = parse(argv, env)?;
    apply(&flags)?;
    flags.start_log();
    Ok(flags)
}

/// Returns whether `word` stands where a global flag may: a flag-like word that is neither
/// `--` nor one of [`COMMAND_FLAGS`].
#[must_use]
fn is_flag(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-') && word != "--" && !COMMAND_FLAGS.contains(&word)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[must_use]
    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[must_use]
    fn parsed(text: &str) -> Flags {
        parse(words(text), &FlagsEnv::default()).unwrap()
    }

    #[must_use]
    fn parsed_with(text: &str, remote: Option<&str>, verbose: Option<&str>) -> Flags {
        let env = FlagsEnv {
            remote: remote.map(str::to_owned),
            verbose: verbose.map(str::to_owned),
        };
        parse(words(text), &env).unwrap()
    }

    #[must_use]
    fn refused(text: &str) -> FlagsError {
        parse(words(text), &FlagsEnv::default()).unwrap_err()
    }

    #[must_use]
    fn stripped(at: usize, word: &str) -> FlagsStripped {
        FlagsStripped {
            at,
            word: word.to_owned(),
        }
    }

    #[test]
    fn parse_should_leave_command_words_in_order() {
        let flags = parsed("board ls --label x");
        assert_eq!(flags.args, words("board ls --label x"));
        assert_eq!(flags.after, 0);
        assert!(!flags.dashed);
        assert!(flags.stripped.is_empty());
    }

    #[test]
    fn parse_should_take_each_switch_before_the_first_command_word() {
        let flags = parsed("--remote --detach --priority test lint");
        assert_eq!(flags.args, words("test lint"));
        assert!(flags.remote);
        assert!(flags.detach);
        assert!(flags.priority);
    }

    #[test]
    fn parse_should_leave_a_global_flag_after_the_first_command_word_to_the_command() {
        let flags = parsed("test --remote -C x --agent y");
        assert_eq!(flags.args, words("test --remote -C x --agent y"));
        assert!(!flags.remote);
        assert!(flags.chdirs.is_empty());
        assert_eq!(flags.agent, None);
    }

    #[test]
    fn parse_should_strip_verbosity_words_after_the_command_word_up_to_the_dashes() {
        let flags = parsed("test -v a -q -vv b --verbose -- -v c");
        assert_eq!(flags.args, words("test a b -v c"));
        assert_eq!(
            flags.stripped,
            vec![
                stripped(2, "-v"),
                stripped(3, "-q"),
                stripped(3, "-vv"),
                stripped(4, "--verbose"),
            ]
        );
        assert_eq!((flags.level, flags.quiet), (4, true));
        assert_eq!(flags.after, 2);
    }

    #[test]
    fn stripped_words_should_go_back_in_place_when_reinserted_from_last_to_first() {
        for line in [
            "test -v a -q -vv b --verbose -- -v c",
            "test -v -- b",
            "-v test -q",
            "test a b",
        ] {
            let flags = parsed(line);
            let mut args = flags.args.clone();
            let tail = args.split_off(args.len() - flags.after);
            for entry in flags.stripped.iter().rev() {
                args.insert(entry.at - 1, entry.word.clone());
            }
            if flags.dashed {
                args.push("--".to_owned());
            }
            args.extend(tail);
            let mut expected = words(line);
            expected.drain(..flags.leading.len());
            assert_eq!(args, expected, "{line}");
        }
    }

    #[test]
    fn parse_should_keep_leading_and_stripped_verbosity_apart() {
        let flags = parsed("-v --quiet test -v");
        assert_eq!(flags.leading, words("-v --quiet"));
        assert_eq!(flags.stripped, vec![stripped(2, "-v")]);
        assert_eq!((flags.level, flags.quiet), (2, true));
    }

    #[test]
    fn parse_should_drop_the_first_dashes_and_count_the_words_after_them() {
        let flags = parsed("test a -- --remote -- b");
        assert_eq!(flags.args, words("test a --remote -- b"));
        assert_eq!(flags.after, 3);
        assert!(flags.dashed);
        let flags = parsed("-v -- --remote");
        assert_eq!(flags.args, words("--remote"));
        assert_eq!((flags.after, flags.level), (1, 1));
        let flags = parsed("test --");
        assert_eq!((flags.after, flags.dashed), (0, true));
    }

    #[test]
    fn parse_should_refuse_an_unknown_flag_before_the_first_command_word() {
        assert_eq!(
            refused("--version"),
            FlagsError::Unknown("--version".to_owned())
        );
        assert_eq!(refused("-x test"), FlagsError::Unknown("-x".to_owned()));
        assert_eq!(refused("-vx test"), FlagsError::Unknown("-vx".to_owned()));
        let sentence = FlagsError::Unknown("-x".to_owned()).to_string();
        assert_eq!(sentence, "The flag `-x` is not a global flag of dev.");
    }

    #[test]
    fn parse_should_hand_a_help_flag_or_a_lone_dash_to_the_command() {
        assert_eq!(parsed("-v -h").args, words("-h"));
        assert_eq!(parsed("--help board").args, words("--help board"));
        assert_eq!(parsed("- x").args, words("- x"));
    }

    #[test]
    fn parse_should_let_local_win_and_report_the_conflict() {
        let flags = parsed("--local --remote test");
        assert!(!flags.remote);
        assert!(flags.conflict);
        assert!(flags.local_flag);
        assert!(!parsed_with("--local test", Some("1"), None).remote);
        assert!(!parsed_with("--local test", Some("1"), None).conflict);
    }

    #[test]
    fn parse_should_read_dev_remote() {
        assert!(parsed_with("test", Some("1"), None).remote);
        assert!(parsed_with("test", Some("yes"), None).remote);
        for value in ["", "0", "no", "false"] {
            assert!(!parsed_with("test", Some(value), None).remote, "{value}");
        }
        assert!(parsed_with("test", Some("no"), None).env_local);
        assert!(!parsed_with("test", Some(""), None).env_local);
    }

    #[test]
    fn parse_should_count_verbosity_and_cap_it() {
        assert_eq!(parsed("-v test").level, 1);
        assert_eq!(parsed("-v --verbose test").level, 2);
        assert_eq!(parsed("-vvvvvv test").level, log::MAX_VERBOSITY);
        assert!(parsed("-q test").quiet);
    }

    #[test]
    fn parse_should_fall_back_to_verbose_when_no_flag_is_given() {
        let flags = parsed_with("test", None, Some("3"));
        assert_eq!(flags.level, 3);
        assert_eq!(flags.env_verbose.as_deref(), Some("3"));
        assert_eq!(parsed_with("-v test", None, Some("3")).level, 1);
        assert_eq!(parsed_with("test -q", None, Some("3")).level, 0);
    }

    #[test]
    fn parse_should_take_a_job_timeout_value_unless_it_is_a_flag() {
        let flags = parsed("--remote --job-timeout 3600 test");
        assert_eq!(flags.job_timeout.as_deref(), Some("3600"));
        assert_eq!(flags.args, words("test"));
        let flags = parsed("--remote --job-timeout --detach test");
        assert_eq!(flags.job_timeout.as_deref(), Some(""));
        assert!(flags.detach);
        let flags = parsed("--job-timeout -- x");
        assert_eq!(flags.job_timeout.as_deref(), Some(""));
        assert_eq!(flags.after, 1);
        assert_eq!(parsed("--job-timeout").job_timeout.as_deref(), Some(""));
    }

    #[test]
    fn parse_should_collect_every_chdir_in_order() {
        let flags = parsed("-C a -C b test");
        assert_eq!(flags.chdirs, words("a b"));
        assert_eq!(flags.args, words("test"));
    }

    #[test]
    fn parse_should_refuse_a_flag_missing_its_value() {
        assert_eq!(refused("-C"), FlagsError::ChdirNeedsDir);
        assert_eq!(refused("--agent"), FlagsError::AgentNeedsName);
        assert_eq!(refused("-l"), FlagsError::ScriptNeedsFile);
        let empty = parse(vec!["-C".to_owned(), String::new()], &FlagsEnv::default());
        assert_eq!(empty.unwrap_err(), FlagsError::ChdirNeedsDir);
        assert_eq!(
            FlagsError::ChdirNeedsDir.to_string(),
            "The flag `-C` needs a directory."
        );
        assert_eq!(
            FlagsError::AgentNeedsName.to_string(),
            "The --agent flag needs a name."
        );
    }

    #[test]
    fn parse_should_take_an_agent_name() {
        let flags = parsed("--agent dotfiles/runner test");
        assert_eq!(flags.agent.as_deref(), Some("dotfiles/runner"));
        assert_eq!(flags.args, words("test"));
    }

    #[test]
    fn parse_should_hand_every_word_after_a_script_to_it() {
        let flags = parsed("-v -l run.luau a -v --remote -- b");
        let script = flags.script.unwrap();
        assert_eq!(script.path, "run.luau");
        assert_eq!(script.args, words("a -v --remote -- b"));
        assert_eq!(flags.level, 1);
        assert!(!flags.remote);
        assert!(flags.args.is_empty());
        assert!(flags.stripped.is_empty());
    }

    #[test]
    fn global_should_find_every_row_and_each_run_of_v() {
        for (word, kind) in GLOBALS {
            assert_eq!(global(word), Some(kind));
        }
        assert_eq!(global("-vvv"), Some(FlagsKind::Verbosity));
        assert_eq!(global("-x"), None);
    }
}

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::{self, PipeWriter, Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

use crate::native::signals::{self, Foreground, Start};
use crate::runtime::{self, SIGNAL_EXIT_BASE};
use crate::{Error, Result, log, overlay};

/// Exit status of a command that could not be found, the status a shell gives.
pub const NOT_FOUND_EXIT: i32 = 127;

/// Exit status of a command that was found but could not be started.
pub const NOT_EXECUTABLE_EXIT: i32 = 126;

/// Exit status of a timed command that hit its limit or was killed.
pub const TIMEOUT_EXIT: i32 = 124;

/// Exit statuses of a command that a TERM or KILL ended, which a timed run reports as a timeout.
const KILLED_EXITS: [i32; 2] = [
    SIGNAL_EXIT_BASE + signals::KILL,
    SIGNAL_EXIT_BASE + signals::TERM,
];

/// How long a timed command may take to end after TERM before KILL follows.
const KILL_GRACE: Duration = Duration::from_secs(1);

/// How long a spawned command may take to end after TERM at exit before KILL follows.
const STOP_GRACE: Duration = Duration::from_millis(250);

/// How often a timed run looks at its command and its output.
const POLL: Duration = Duration::from_millis(50);

/// How often a wait for an exit looks at the command.
const WAIT_POLL: Duration = Duration::from_millis(10);

/// How many quiet polls after a command exits end the wait for its output.
const IDLE_POLLS: u32 = 3;

/// The device that discards what is written to it.
#[cfg(unix)]
const DEV_NULL: &str = "/dev/null";

/// The device that discards what is written to it.
#[cfg(windows)]
const DEV_NULL: &str = "NUL";

/// An open stream a child takes as its standard output or error.
#[cfg(unix)]
type Owned = std::os::fd::OwnedFd;

/// An open stream a child takes as its standard output or error.
#[cfg(windows)]
type Owned = std::os::windows::io::OwnedHandle;

/// Where one of a command's output streams goes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Sink {
    /// Dev's own stream.
    #[default]
    Inherit,
    /// /dev/null.
    Null,
    /// The end of a file, created when missing.
    Append(PathBuf),
    /// The command's standard output, for its standard error.
    Merge,
}

/// How a command is placed among process groups.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Group {
    /// Dev's own group.
    #[default]
    Shared,
    /// A new group of its own.
    Own,
}

/// Where a command's standard input comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Input {
    /// Dev's own standard input.
    Inherit,
    /// /dev/null.
    Null,
    /// A pipe dev writes to.
    Pipe,
}

/// A command to start: its words, environment, folder, streams and process group.
#[derive(Clone, Debug, Default)]
pub struct Spec {
    /// The program and its arguments, with at least one word.
    pub argv: Vec<OsString>,
    /// Variables set for the command, over dev's own environment.
    pub env_set: Vec<(OsString, OsString)>,
    /// Variables removed from the command's environment.
    pub env_unset: Vec<OsString>,
    /// Folder to run in.
    pub cwd: Option<PathBuf>,
    /// Where standard output goes.
    pub stdout: Sink,
    /// Where standard error goes.
    pub stderr: Sink,
    /// Process group placement.
    pub group: Group,
    /// Whether standard input is /dev/null.
    pub null_stdin: bool,
}

impl Spec {
    /// Returns the input mode a plain run uses.
    #[must_use]
    pub fn input(&self) -> Input {
        if self.null_stdin {
            Input::Null
        } else {
            Input::Inherit
        }
    }

    /// Builds the command, with `out` as its standard output when the spec leaves it alone.
    ///
    /// # Errors
    ///
    /// Returns the error of opening a file or /dev/null for a stream.
    pub fn command(&self, input: Input, out: Option<PipeWriter>) -> Result<Command> {
        let mut command = Command::new(&self.argv[0]);
        command.args(&self.argv[1..]);
        overlay::apply(&mut command);
        for name in &self.env_unset {
            command.env_remove(name);
        }
        for (name, value) in &self.env_set {
            command.env(name, value);
        }
        if let Some(cwd) = &self.cwd {
            command.current_dir(cwd);
        }
        command.stdin(match input {
            Input::Inherit => Stdio::inherit(),
            Input::Null => Stdio::null(),
            Input::Pipe => Stdio::piped(),
        });
        let stdout = match &self.stdout {
            Sink::Inherit => out.map(Owned::from),
            Sink::Null => Some(open_null()?),
            Sink::Append(path) => Some(open_append(path)?),
            Sink::Merge => None,
        };
        let stderr = match &self.stderr {
            Sink::Inherit => None,
            Sink::Null => Some(open_null()?),
            Sink::Append(path) => Some(open_append(path)?),
            Sink::Merge => Some(match &stdout {
                Some(fd) => fd
                    .try_clone()
                    .map_err(|error| Error::io("duplicate standard output", error))?,
                None => {
                    dup_stdout().map_err(|error| Error::io("duplicate standard output", error))?
                }
            }),
        };
        if let Some(fd) = stdout {
            command.stdout(Stdio::from(fd));
        }
        if let Some(fd) = stderr {
            command.stderr(Stdio::from(fd));
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;

            if self.group == Group::Own {
                command.process_group(0);
            }
        }
        Ok(command)
    }
}

/// Duplicates dev's standard output.
#[cfg(unix)]
fn dup_stdout() -> io::Result<Owned> {
    use std::os::fd::AsFd;

    io::stdout().as_fd().try_clone_to_owned()
}

/// Duplicates dev's standard output.
#[cfg(windows)]
fn dup_stdout() -> io::Result<Owned> {
    use std::os::windows::io::AsHandle;

    io::stdout().as_handle().try_clone_to_owned()
}

/// Opens the null device for writing.
fn open_null() -> Result<Owned> {
    OpenOptions::new()
        .write(true)
        .open(DEV_NULL)
        .map(Owned::from)
        .map_err(|error| Error::io("open the null device", error))
}

/// Opens `path` for appending, creating it when missing.
fn open_append(path: &PathBuf) -> Result<Owned> {
    OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)
        .map(Owned::from)
        .map_err(|error| Error::io(format!("open {}", path.display()), error))
}

/// Starts `command`, with the program's name in the error.
fn start(command: &mut Command, spec: &Spec) -> Result<Child> {
    command
        .spawn()
        .map_err(|error| Error::io(format!("start {}", spec.argv[0].to_string_lossy()), error))
}

/// Returns the exit status a finished command reports: its code, or 128 plus its signal.
///
/// Windows has no signal, and its commands always have a code.
#[must_use]
pub fn decode(status: ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;

        status
            .code()
            .unwrap_or_else(|| SIGNAL_EXIT_BASE + status.signal().unwrap_or(0))
    }
    #[cfg(windows)]
    {
        status.code().unwrap_or(SIGNAL_EXIT_BASE)
    }
}

/// Returns the exit status a shell gives for a command that failed to start with `error`.
#[must_use]
pub fn failed_code(error: &Error) -> i32 {
    match error {
        Error::Io { source, .. } if source.kind() == io::ErrorKind::NotFound => NOT_FOUND_EXIT,
        _ => NOT_EXECUTABLE_EXIT,
    }
}

/// Returns the system's text for `error`, without the `(os error N)` tail.
#[must_use]
pub fn reason(error: &Error) -> String {
    let text = match error {
        Error::Io { source, .. } => source.to_string(),
        other => other.to_string(),
    };
    match text.rfind(" (os error ") {
        Some(at) => text[..at].to_owned(),
        None => text,
    }
}

/// Runs the command with dev's streams and waits for it.
///
/// # Errors
///
/// Returns the error of starting the command.
pub fn run(spec: &Spec) -> Result<i32> {
    let mut command = spec.command(spec.input(), None)?;
    let pending = runtime::interrupted();
    let started = Instant::now();
    let mut child = start(&mut command, spec)?;
    let foreground = enter_foreground(&child, spec.group, pending);
    let status = child
        .wait()
        .map_err(|error| Error::io("wait for the command", error))?;
    drop(foreground);
    raise_interrupt()?;
    let code = decode(status);
    log_spawn(spec, started, code);
    Ok(code)
}

/// Logs a finished command when spawns are logged.
fn log_spawn(spec: &Spec, started: Instant, code: i32) {
    if !log::spawns() {
        return;
    }
    let argv: Vec<String> = spec
        .argv
        .iter()
        .map(|word| word.to_string_lossy().into_owned())
        .collect();
    let dir = spec
        .cwd
        .clone()
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    log::spawn(&argv, &dir, Some(code), started.elapsed());
}

/// Raises the interrupt that arrived, if any, as a dev error that `is_interrupt` recognizes.
fn raise_interrupt() -> Result<()> {
    runtime::check_interrupt().map_err(|error| Error::Message(runtime::message(&error)))
}

/// Makes `child` the foreground child, and forwards a signal that arrived while it started.
fn enter_foreground(child: &Child, group: Group, pending_before: bool) -> Foreground {
    let pid = pid_of(child);
    Foreground::enter(pid, group == Group::Own, Start::from(pending_before))
}

/// Runs the command, writing `input` to its standard input, and collects its standard output.
///
/// # Errors
///
/// Returns the error of starting the command.
pub fn capture(spec: &Spec, input: Option<&[u8]>) -> Result<(Vec<u8>, i32)> {
    let (mut reader, writer) = io::pipe().map_err(|error| Error::io("open a pipe", error))?;
    let mode = match input {
        Some(_) => Input::Pipe,
        None => spec.input(),
    };
    let mut command = spec.command(mode, Some(writer))?;
    let pending = runtime::interrupted();
    let started = Instant::now();
    let mut child = start(&mut command, spec)?;
    drop(command);
    let feeder = feed(&mut child, input);
    let foreground = enter_foreground(&child, spec.group, pending);
    let mut out = Vec::new();
    let read = reader.read_to_end(&mut out);
    let status = child.wait();
    if let Some(feeder) = feeder {
        drop(feeder.join());
    }
    drop(foreground);
    read.map_err(|error| Error::io("read the command's output", error))?;
    let status = status.map_err(|error| Error::io("wait for the command", error))?;
    raise_interrupt()?;
    let code = decode(status);
    log_spawn(spec, started, code);
    Ok((out, code))
}

/// Writes `input` to the child's standard input from a thread and then closes it.
///
/// A child that stops reading early is not an error.
fn feed(child: &mut Child, input: Option<&[u8]>) -> Option<thread::JoinHandle<()>> {
    let data = input?.to_vec();
    let mut stdin = child.stdin.take()?;
    Some(thread::spawn(move || {
        drop(stdin.write_all(&data));
    }))
}

/// Returns the process id of `child` as the signed number kill takes.
fn pid_of(child: &Child) -> i32 {
    i32::try_from(child.id()).unwrap_or(i32::MAX)
}

/// Sends `signal` to the group `pgid` that `child` leads, returning whether it was delivered.
#[cfg(unix)]
fn signal_group(_child: &mut Child, pgid: i32, signal: i32) -> bool {
    signals::send(-pgid, signal)
}

/// Ends `child` for TERM or KILL, returning whether it was ended.
///
/// Windows has no process group and no other signal, so the processes `child` started stay.
#[cfg(windows)]
fn signal_group(child: &mut Child, _pgid: i32, signal: i32) -> bool {
    matches!(signal, signals::TERM | signals::KILL) && child.kill().is_ok()
}

/// Sends TERM to the group, gives the leader a second to end, then sends KILL.
fn stop_group(child: &mut Child, pgid: i32) -> Result<()> {
    let _ = signal_group(child, pgid, signals::TERM);
    let deadline = Instant::now() + KILL_GRACE;
    while Instant::now() < deadline {
        let ended = child
            .try_wait()
            .map_err(|error| Error::io("wait for the command", error))?;
        if ended.is_some() {
            break;
        }
        thread::sleep(WAIT_POLL);
    }
    let _ = signal_group(child, pgid, signals::KILL);
    child
        .wait()
        .map(drop)
        .map_err(|error| Error::io("wait for the command", error))
}

/// The shell that runs the watcher, by absolute path so no folder on `PATH` can stand in for it.
#[cfg(unix)]
const WATCHER_SHELL: &str = "/bin/sh";

/// Script of the watcher: kills group `$1` when its input ends before dev wrote the release line.
#[cfg(unix)]
const WATCHER_SCRIPT: &str =
    r#"IFS= read -r released; [ -n "$released" ] || kill -KILL "-$1" 2>/dev/null"#;

/// Stands in for the watcher on Windows, which has no process group to kill.
#[cfg(windows)]
#[derive(Debug)]
struct Watcher;

#[cfg(windows)]
impl Watcher {
    /// Starts nothing.
    fn start(_pgid: i32) -> Result<Self> {
        Ok(Self)
    }

    /// Releases nothing.
    fn release(self) {}
}

/// A process that kills a timed command's group when dev dies before it released the watcher.
#[cfg(unix)]
#[derive(Debug)]
struct Watcher {
    /// The watcher itself.
    child: Child,
    /// The pipe it blocks on, held open by dev.
    stdin: std::process::ChildStdin,
}

#[cfg(unix)]
impl Watcher {
    /// Starts a watcher for process group `pgid`.
    fn start(pgid: i32) -> Result<Self> {
        use std::os::unix::process::CommandExt;

        let mut command = Command::new(WATCHER_SHELL);
        command
            .args(["-c", WATCHER_SCRIPT, "sh", &pgid.to_string()])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        overlay::apply(&mut command);
        let mut child = command
            .spawn()
            .map_err(|error| Error::io("start the watcher", error))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| Error::Message("the watcher has no input".to_owned()))?;
        Ok(Self { child, stdin })
    }

    /// Tells the watcher dev is done, so it leaves the group alone, and waits for it to end.
    fn release(self) {
        let Self {
            mut child,
            mut stdin,
        } = self;
        drop(stdin.write_all(b"x\n"));
        drop(stdin);
        drop(child.wait());
    }
}

/// Reads `reader` in a thread and sends each piece to the returned channel until it ends.
fn pump(mut reader: impl Read + Send + 'static) -> mpsc::Receiver<Vec<u8>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = [0u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    if sender.send(buffer[..count].to_vec()).is_err() {
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
    });
    receiver
}

/// Runs the command in its own process group and collects its output, limited to `secs`.
///
/// `on_text` gets each piece of output as it arrives. A `secs` of 0 or less sets no limit. With
/// `reap`, a command that ends on its own has its group killed. A SIGINT, SIGTERM or SIGHUP to
/// dev stops the group.
///
/// # Errors
///
/// Returns the start error, or the error `on_text` returned, after the group was killed.
pub fn capture_timed(
    spec: &Spec,
    secs: f64,
    input: Option<&[u8]>,
    reap: bool,
    on_text: &mut dyn FnMut(&[u8]) -> Result<()>,
) -> Result<(Vec<u8>, i32)> {
    let (reader, writer) = io::pipe().map_err(|error| Error::io("open a pipe", error))?;
    let mode = if input.is_some() {
        Input::Pipe
    } else {
        Input::Null
    };
    let mut command = spec.command(mode, Some(writer))?;
    let pending = runtime::interrupted();
    let started = Instant::now();
    let mut child = start(&mut command, spec)?;
    drop(command);
    let pgid = pid_of(&child);
    let foreground = enter_foreground(&child, Group::Own, pending);
    let watcher = match Watcher::start(pgid) {
        Ok(watcher) => watcher,
        Err(error) => {
            let _ = signal_group(&mut child, pgid, signals::KILL);
            drop(child.wait());
            return Err(error);
        }
    };
    let feeder = feed(&mut child, input);
    let result = watch_output(&mut child, pgid, secs, reap, &pump(reader), on_text);
    if result.is_err() {
        let _ = signal_group(&mut child, pgid, signals::KILL);
        drop(child.wait());
    }
    watcher.release();
    drop(foreground);
    if let Some(feeder) = feeder {
        drop(feeder.join());
    }
    let (out, code, interrupted) = result?;
    if interrupted {
        raise_interrupt()?;
    }
    let code = if KILLED_EXITS.contains(&code) {
        TIMEOUT_EXIT
    } else {
        code
    };
    log_spawn(spec, started, code);
    Ok((out, code))
}

/// Collects output and the exit status of a timed command.
fn watch_output(
    child: &mut Child,
    pgid: i32,
    secs: f64,
    reap: bool,
    output: &mpsc::Receiver<Vec<u8>>,
    on_text: &mut dyn FnMut(&[u8]) -> Result<()>,
) -> Result<(Vec<u8>, i32, bool)> {
    let started = Instant::now();
    let mut out = Vec::new();
    let mut code: Option<i32> = None;
    let mut open = true;
    let mut idle = 0;
    let mut interrupted = false;
    let mut stopped = false;
    loop {
        if open {
            match output.recv_timeout(POLL) {
                Ok(chunk) => {
                    idle = 0;
                    out.extend_from_slice(&chunk);
                    on_text(&chunk)?;
                }
                Err(RecvTimeoutError::Timeout) => {
                    if code.is_some() {
                        idle += 1;
                    }
                }
                Err(RecvTimeoutError::Disconnected) => open = false,
            }
        } else if code.is_none() {
            thread::sleep(POLL);
        }
        if code.is_none() {
            let ended = child
                .try_wait()
                .map_err(|error| Error::io("wait for the command", error))?;
            if let Some(status) = ended {
                code = Some(decode(status));
                if reap {
                    let _ = signal_group(child, pgid, signals::KILL);
                }
            } else if runtime::interrupted() {
                stop_group(child, pgid)?;
                code = Some(runtime::interrupt_code());
                interrupted = true;
                stopped = true;
            } else if secs > 0.0 && started.elapsed().as_secs_f64() > secs {
                stop_group(child, pgid)?;
                code = Some(TIMEOUT_EXIT);
                stopped = true;
            }
        }
        // A Windows grandchild outlives its killed parent and keeps the pipe open and busy
        if code.is_some() && (!open || idle >= IDLE_POLLS || (cfg!(windows) && stopped)) {
            break;
        }
    }
    Ok((out, code.unwrap_or(TIMEOUT_EXIT), interrupted))
}

/// A command started by `spawn` that dev has not finished with.
#[derive(Debug)]
struct Live {
    /// The running command.
    child: Child,
    /// Whether it outlives dev.
    detached: bool,
    /// Its exit status once it ended.
    code: Option<i32>,
}

/// Commands started by `spawn`, by process id.
static LIVE: Mutex<BTreeMap<u32, Live>> = Mutex::new(BTreeMap::new());

/// Runs `f` on the table of spawned commands.
fn with_live<R>(f: impl FnOnce(&mut BTreeMap<u32, Live>) -> R) -> R {
    f(&mut LIVE.lock().unwrap_or_else(PoisonError::into_inner))
}

/// Starts the command without waiting and returns its process id.
///
/// A detached command is left running when dev exits.
///
/// # Errors
///
/// Returns the error of starting the command.
pub fn spawn(spec: &Spec, detached: bool) -> Result<u32> {
    let mut command = spec.command(spec.input(), None)?;
    let child = start(&mut command, spec)?;
    let pid = child.id();
    with_live(|live| {
        live.insert(
            pid,
            Live {
                child,
                detached,
                code: None,
            },
        );
    });
    Ok(pid)
}

/// Waits up to `secs` seconds, or for as long as it takes with `None`, for a spawned command.
///
/// Returns `None` for an unknown id, and `Some(None)` while the command still runs.
#[must_use]
pub fn wait(pid: u32, secs: Option<f64>) -> Option<Option<i32>> {
    let deadline = secs.map(|secs| Instant::now() + Duration::from_secs_f64(secs.max(0.0)));
    loop {
        let state = with_live(|live| {
            let entry = live.get_mut(&pid)?;
            if entry.code.is_none() {
                entry.code = entry.child.try_wait().ok().flatten().map(decode);
            }
            Some(entry.code)
        })?;
        let expired = deadline.is_some_and(|deadline| Instant::now() >= deadline);
        if state.is_some() || expired || runtime::interrupted() {
            return Some(state);
        }
        thread::sleep(WAIT_POLL);
    }
}

/// Sends `signal` to the group of a spawned command and returns whether it was delivered.
#[must_use]
pub fn kill(pid: u32, signal: i32) -> bool {
    with_live(|live| {
        live.get_mut(&pid).is_some_and(|entry| {
            let pgid = i32::try_from(pid).unwrap_or(i32::MAX);
            signal_group(&mut entry.child, pgid, signal)
        })
    })
}

/// Stops every spawned command that is not detached, TERM first and KILL after a short wait.
pub fn stop_spawned() {
    let pids: Vec<u32> = with_live(|live| {
        live.iter()
            .filter(|(_, entry)| !entry.detached && entry.code.is_none())
            .map(|(pid, _)| *pid)
            .collect()
    });
    for pid in &pids {
        let _ = kill(*pid, signals::TERM);
    }
    let deadline = Instant::now() + STOP_GRACE;
    while Instant::now() < deadline
        && pids
            .iter()
            .any(|pid| matches!(wait(*pid, Some(0.0)), Some(None)))
    {
        thread::sleep(WAIT_POLL);
    }
    for pid in &pids {
        let _ = kill(*pid, signals::KILL);
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::ffi::OsString;
    use std::io;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    use super::{
        Error, Group, NOT_EXECUTABLE_EXIT, NOT_FOUND_EXIT, SIGNAL_EXIT_BASE, Sink, Spec,
        TIMEOUT_EXIT, WATCHER_SCRIPT, capture, capture_timed, decode, failed_code, reason, signals,
    };

    fn spec(words: &[&str]) -> Spec {
        Spec {
            argv: words.iter().map(OsString::from).collect(),
            ..Spec::default()
        }
    }

    fn io_error(code: i32) -> Error {
        Error::io("start x", io::Error::from_raw_os_error(code))
    }

    #[test]
    fn reason_should_drop_the_os_error_tail() {
        let error = io_error(2);
        assert!(!reason(&error).contains("os error"));
        assert_eq!(failed_code(&error), NOT_FOUND_EXIT);
    }

    #[test]
    fn failed_code_should_say_126_for_a_file_that_cannot_run() {
        assert_eq!(failed_code(&io_error(13)), NOT_EXECUTABLE_EXIT);
    }

    #[test]
    fn watcher_script_should_kill_the_group_under_dash_when_its_input_ends() {
        if Command::new("dash").args(["-c", "exit"]).status().is_err() {
            return;
        }
        let mut sleeper = Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let pgid = sleeper.id().to_string();
        let mut dash = Command::new("dash")
            .args(["-c", WATCHER_SCRIPT, "dash", &pgid])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        drop(dash.stdin.take());
        assert!(dash.wait().unwrap().success());
        let status = sleeper.wait().unwrap();
        assert_eq!(decode(status), SIGNAL_EXIT_BASE + signals::KILL);
    }

    #[test]
    fn decode_should_add_the_signal_to_128() {
        let status = Command::new("sh")
            .args(["-c", "kill -TERM $$"])
            .status()
            .unwrap();
        assert_eq!(decode(status), SIGNAL_EXIT_BASE + signals::TERM);
    }

    #[test]
    fn capture_should_keep_words_with_quotes_and_spaces_unchanged() {
        let (out, code) = capture(&spec(&["printf", "%s", "a b;$(id)'\"`"]), None).unwrap();
        assert_eq!(out, b"a b;$(id)'\"`");
        assert_eq!(code, 0);
    }

    #[test]
    fn capture_should_feed_the_input_to_the_command() {
        let (out, code) = capture(&spec(&["cat"]), Some(b"fed\n")).unwrap();
        assert_eq!(out, b"fed\n");
        assert_eq!(code, 0);
    }

    #[test]
    fn capture_timed_should_report_124_when_the_limit_hits() {
        let mut seen = Vec::new();
        let mut own = spec(&["sh", "-c", "echo before; sleep 30"]);
        own.group = Group::Own;
        let (out, code) = capture_timed(&own, 0.3, None, false, &mut |text| {
            seen.extend_from_slice(text);
            Ok(())
        })
        .unwrap();
        assert_eq!(code, TIMEOUT_EXIT);
        assert_eq!(out, b"before\n");
        assert_eq!(seen, out);
    }

    #[test]
    fn capture_should_keep_a_megabyte_on_each_stream_when_they_merge() {
        let mut both = spec(&[
            "sh",
            "-c",
            "head -c 1000000 /dev/zero; head -c 1000000 /dev/zero >&2",
        ]);
        both.stderr = Sink::Merge;
        let (out, code) = capture(&both, None).unwrap();
        assert_eq!(out.len(), 2_000_000);
        assert_eq!(code, 0);
    }

    #[test]
    fn capture_should_pass_a_large_input_through_to_a_large_output() {
        let input = vec![b'x'; 1_000_000];
        let (out, code) = capture(&spec(&["cat"]), Some(&input)).unwrap();
        assert_eq!(out, input);
        assert_eq!(code, 0);
    }
}

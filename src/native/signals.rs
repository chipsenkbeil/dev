use std::sync::{Mutex, MutexGuard, PoisonError};

/// Signal number of SIGHUP.
pub const HUP: i32 = 1;

/// Signal number of SIGINT.
pub const INT: i32 = 2;

/// Signal number of SIGQUIT.
pub const QUIT: i32 = 3;

/// Signal number of SIGKILL.
pub const KILL: i32 = 9;

/// Signal number of SIGPIPE.
pub const PIPE: i32 = 13;

/// Signal number of SIGTERM.
pub const TERM: i32 = 15;

/// The foreground child a signal is forwarded to, and the signal that came before there was one.
static FOREGROUND: Mutex<State> = Mutex::new(State::new());

/// A signal that came while no child was in the foreground.
#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Parked {
    /// Number of the signal.
    signal: i32,
    /// Who delivered it.
    sender: Sender,
}

/// A signal to pass on to a child.
#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Forward {
    /// Child that gets the signal.
    pid: i32,
    /// Whether that child leads its own process group.
    own_group: bool,
    /// Number of the signal.
    signal: i32,
    /// Who delivered it.
    sender: Sender,
}

/// What the signal thread and the thread that starts a child agree on, under one lock.
#[derive(Debug)]
struct State {
    /// The foreground child, 0 for none.
    pid: i32,
    /// Whether the foreground child leads its own process group.
    own_group: bool,
    /// The last signal that found no foreground child while the interrupt was pending.
    #[cfg(unix)]
    parked: Option<Parked>,
}

impl State {
    /// Returns the state with no foreground child.
    #[must_use]
    const fn new() -> Self {
        Self {
            pid: 0,
            own_group: false,
            #[cfg(unix)]
            parked: None,
        }
    }

    /// Decides where a signal goes: to the foreground child while the interrupt is still
    /// pending, and otherwise nowhere, with the signal kept for the next child to enter.
    #[cfg(unix)]
    fn deliver(&mut self, signal: i32, sender: Sender, pending: bool) -> Option<Forward> {
        if !pending {
            return None;
        }
        match forward_target((self.pid, self.own_group), pending) {
            Some((pid, own_group)) => Some(Forward {
                pid,
                own_group,
                signal,
                sender,
            }),
            None => {
                self.parked = Some(Parked { signal, sender });
                None
            }
        }
    }

    /// Takes the signal kept for the child that is now in the foreground, when it is still due.
    #[cfg(unix)]
    fn claim(&mut self, due: bool) -> Option<Forward> {
        let parked = self.parked.take().filter(|_| due)?;
        Some(Forward {
            pid: self.pid,
            own_group: self.own_group,
            signal: parked.signal,
            sender: parked.sender,
        })
    }
}

/// Locks the foreground child, even after a thread panicked while holding it.
fn foreground() -> MutexGuard<'static, State> {
    FOREGROUND.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Sends `signal` to process `pid`, or to the process group `-pid` when `pid` is negative.
///
/// Returns whether the signal was delivered.
#[cfg(unix)]
#[must_use]
pub fn send(pid: i32, signal: i32) -> bool {
    use rustix::process::{self, Pid, Signal};

    let (Some(target), Some(signal)) = (
        Pid::from_raw(pid.saturating_abs()),
        Signal::from_named_raw(signal),
    ) else {
        return false;
    };
    let sent = if pid < 0 {
        process::kill_process_group(target, signal)
    } else {
        process::kill_process(target, signal)
    };
    sent.is_ok()
}

/// Whether an interrupt was already pending when a child started.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    /// No interrupt was pending.
    Clear,
    /// An interrupt was pending, so the child started after it.
    Interrupted,
}

impl From<bool> for Start {
    fn from(pending: bool) -> Self {
        if pending {
            Self::Interrupted
        } else {
            Self::Clear
        }
    }
}

/// Keeps a child as the target of forwarded signals until it is dropped.
#[derive(Debug)]
pub struct Foreground {
    /// Child that was the target before this one.
    previous_pid: i32,
    /// Whether that child led its own group.
    previous_own_group: bool,
}

impl Foreground {
    /// Makes `pid` the child that SIGINT, SIGTERM and SIGHUP are forwarded to.
    ///
    /// A child that leads its own group gets the signal for the whole group. A child in dev's own
    /// group already receives a terminal's interrupt, so it gets SIGTERM, and a SIGINT or SIGHUP
    /// that another process sent to dev alone. A signal that came after the child started and
    /// before this call is passed on here, once, unless `start` says the interrupt was already
    /// pending when the child started.
    #[must_use]
    pub fn enter(pid: i32, own_group: bool, start: Start) -> Self {
        let mut state = foreground();
        let previous_pid = std::mem::replace(&mut state.pid, pid);
        let previous_own_group = std::mem::replace(&mut state.own_group, own_group);
        #[cfg(unix)]
        {
            use crate::runtime;

            let due = start == Start::Clear && runtime::interrupted();
            if let Some(due) = state.claim(due) {
                forward(due.pid, due.own_group, due.signal, due.sender);
            }
        }
        #[cfg(windows)]
        let _ = start;
        Self {
            previous_pid,
            previous_own_group,
        }
    }
}

impl Drop for Foreground {
    fn drop(&mut self) {
        let mut state = foreground();
        state.pid = self.previous_pid;
        state.own_group = self.previous_own_group;
    }
}

/// The signals that interrupt dev.
#[cfg(unix)]
const WATCHED: [i32; 3] = [INT, TERM, HUP];

/// Passes `signal` on to the foreground child.
///
/// The handler registered with `flag::register_usize` already recorded the signal for Luau, so
/// recording it again here would interrupt a cleanup that runs after the first interrupt.
#[cfg(unix)]
fn on_signal(origin: &signal_hook::low_level::siginfo::Origin) {
    use crate::runtime;

    let mut state = foreground();
    let pending = runtime::interrupted();
    if let Some(due) = state.deliver(origin.signal, sender_of(origin), pending) {
        forward(due.pid, due.own_group, due.signal, due.sender);
    }
}

/// Picks the child a signal is passed on to: the foreground child while the interrupt is still
/// pending.
///
/// Once Luau has raised the interrupt, the child that was in the foreground when the signal came
/// has ended, and the one there now is a cleanup that started after the signal, so it gets none.
#[cfg(unix)]
#[must_use]
const fn forward_target(current: (i32, bool), pending: bool) -> Option<(i32, bool)> {
    if pending && current.0 > 0 {
        Some(current)
    } else {
        None
    }
}

/// Who delivered a signal to dev.
#[cfg(unix)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Sender {
    /// The terminal or the kernel, which signal dev's whole foreground group.
    Terminal,
    /// Another process, or a sender that is not known.
    Process,
}

/// Tells whether another process sent the signal, as opposed to the terminal or the kernel.
///
/// A terminal delivers its Ctrl-C and its hangup to the whole foreground group, with no sender
/// process behind them (`SI_KERNEL` or a zero pid), so a child in dev's group already has them.
#[cfg(unix)]
#[must_use]
fn sender_of(origin: &signal_hook::low_level::siginfo::Origin) -> Sender {
    if origin.process.is_some_and(|sender| sender.pid > 0) {
        Sender::Process
    } else {
        Sender::Terminal
    }
}

/// Returns whether a signal is passed on to a child in dev's own group.
///
/// TERM always is. INT and HUP are only when another process sent them, since the child
/// already got the terminal's.
#[cfg(unix)]
#[must_use]
const fn reaches_group_child(signal: i32, sender: Sender) -> bool {
    signal == TERM || matches!(sender, Sender::Process)
}

/// Passes `signal` on to child `pid`, to its whole group when it leads one.
#[cfg(unix)]
fn forward(pid: i32, own_group: bool, signal: i32, sender: Sender) {
    if own_group {
        let _ = send(-pid, signal);
    } else if reaches_group_child(signal, sender) {
        let _ = send(pid, signal);
    }
}

/// Returns the number of the signal called `name`, with or without the `SIG` prefix.
#[must_use]
pub fn by_name(name: &str) -> Option<i32> {
    let short = name.strip_prefix("SIG").unwrap_or(name);
    Some(match short {
        "HUP" => HUP,
        "INT" => INT,
        "QUIT" => QUIT,
        "KILL" => KILL,
        "TERM" => TERM,
        #[cfg(unix)]
        "USR1" => rustix::process::Signal::USR1.as_raw(),
        #[cfg(unix)]
        "USR2" => rustix::process::Signal::USR2.as_raw(),
        #[cfg(unix)]
        "CONT" => rustix::process::Signal::CONT.as_raw(),
        #[cfg(unix)]
        "STOP" => rustix::process::Signal::STOP.as_raw(),
        _ => return None,
    })
}

/// Returns whether the process was started with `signal` ignored.
///
/// Only Linux says so, through /proc. Elsewhere no signal counts as ignored.
#[cfg(unix)]
fn is_ignored(signal: i32) -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("SigIgn:"))
                .and_then(|mask| u64::from_str_radix(mask.trim(), 16).ok())
        })
        .is_some_and(|mask| (mask >> (signal - 1)) & 1 == 1)
}

/// Installs nothing on Windows: a Ctrl-C ends dev, and every child on the console, with the
/// console's own default.
#[cfg(windows)]
pub fn install() {}

/// Installs the handlers that turn SIGINT, SIGTERM and SIGHUP into a Luau interrupt.
///
/// A SIGINT or SIGHUP that was ignored at start, as `nohup` leaves it, stays ignored where
/// the process can read that (Linux). SIGTERM is always handled.
#[cfg(unix)]
pub fn install() {
    use std::thread;

    use signal_hook::flag;
    use signal_hook::iterator::SignalsInfo;
    use signal_hook::iterator::exfiltrator::WithOrigin;

    use crate::runtime;

    let handled: Vec<i32> = WATCHED
        .into_iter()
        .filter(|&signal| signal == TERM || !is_ignored(signal))
        .collect();
    for &signal in &handled {
        let slot = runtime::interrupt_slot();
        let _ = flag::register_usize(signal, slot, usize::try_from(signal).unwrap_or(1));
    }
    let Ok(mut signals) = SignalsInfo::<WithOrigin>::new(handled) else {
        return;
    };
    thread::spawn(move || {
        for origin in signals.forever() {
            on_signal(&origin);
        }
    });
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn reaches_group_child_should_pass_term_always_and_int_and_hup_only_when_alone() {
        assert!(reaches_group_child(TERM, Sender::Terminal));
        assert!(reaches_group_child(INT, Sender::Process));
        assert!(reaches_group_child(HUP, Sender::Process));
        assert!(!reaches_group_child(INT, Sender::Terminal));
        assert!(!reaches_group_child(HUP, Sender::Terminal));
    }

    #[test]
    fn claim_should_pass_a_process_sent_int_that_came_before_the_child_to_a_group_child() {
        let mut state = State::new();
        assert_eq!(state.deliver(INT, Sender::Process, true), None);
        state.pid = 42;
        let due = state.claim(true).expect("the parked signal is due");
        assert_eq!((due.pid, due.signal), (42, INT));
        assert!(reaches_group_child(due.signal, due.sender));
        assert_eq!(state.claim(true), None);
    }

    #[test]
    fn claim_should_pass_nothing_when_the_interrupt_was_pending_before_the_child() {
        let mut state = State::new();
        assert_eq!(state.deliver(INT, Sender::Process, true), None);
        state.pid = 42;
        assert_eq!(state.claim(false), None);
    }

    #[test]
    fn deliver_should_forward_to_a_foreground_child_and_park_nothing() {
        let mut state = State::new();
        state.pid = 42;
        let due = state
            .deliver(INT, Sender::Process, true)
            .expect("a forward");
        assert_eq!(due.pid, 42);
        assert_eq!(state.claim(true), None);
        assert_eq!(state.deliver(INT, Sender::Process, false), None);
    }

    #[test]
    fn forward_target_should_skip_a_child_that_started_after_luau_took_the_interrupt() {
        assert_eq!(forward_target((42, true), true), Some((42, true)));
        assert_eq!(forward_target((42, false), false), None);
        assert_eq!(forward_target((0, false), true), None);
    }
}

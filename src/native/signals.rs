use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

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

/// Process id of the foreground child a signal is forwarded to, 0 for none.
static FOREGROUND_PID: AtomicI32 = AtomicI32::new(0);

/// Whether the foreground child leads its own process group.
static FOREGROUND_OWN_GROUP: AtomicBool = AtomicBool::new(false);

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
    /// that another process sent to dev alone.
    #[must_use]
    pub fn enter(pid: i32, own_group: bool) -> Self {
        Self {
            previous_pid: FOREGROUND_PID.swap(pid, Ordering::SeqCst),
            previous_own_group: FOREGROUND_OWN_GROUP.swap(own_group, Ordering::SeqCst),
        }
    }
}

impl Drop for Foreground {
    fn drop(&mut self) {
        FOREGROUND_PID.store(self.previous_pid, Ordering::SeqCst);
        FOREGROUND_OWN_GROUP.store(self.previous_own_group, Ordering::SeqCst);
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
    let pid = FOREGROUND_PID.load(Ordering::SeqCst);
    if pid > 0 {
        let own_group = FOREGROUND_OWN_GROUP.load(Ordering::SeqCst);
        forward(pid, own_group, origin.signal, sender_of(origin));
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

/// Passes the interrupt that is pending on to child `pid`.
///
/// The sender of a pending interrupt is unknown, so a child in dev's group gets only TERM.
#[cfg(unix)]
pub fn forward_pending(pid: i32, own_group: bool) {
    use crate::runtime;

    forward(
        pid,
        own_group,
        runtime::interrupt_code() - runtime::SIGNAL_EXIT_BASE,
        Sender::Terminal,
    );
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
}

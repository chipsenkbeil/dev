use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::{fs, thread};

use rustix::process::{self, Pid, Signal};
use signal_hook::flag;
use signal_hook::iterator::Signals;

use crate::runtime;

/// Signal number of SIGHUP.
pub const HUP: i32 = 1;

/// Signal number of SIGINT.
pub const INT: i32 = 2;

/// Signal number of SIGQUIT.
pub const QUIT: i32 = 3;

/// Signal number of SIGKILL.
pub const KILL: i32 = 9;

/// Signal number of SIGTERM.
pub const TERM: i32 = 15;

/// Process id of the foreground child a signal is forwarded to, 0 for none.
static FOREGROUND_PID: AtomicI32 = AtomicI32::new(0);

/// Whether the foreground child leads its own process group.
static FOREGROUND_OWN_GROUP: AtomicBool = AtomicBool::new(false);

/// Sends `signal` to process `pid`, or to the process group `-pid` when `pid` is negative.
///
/// Returns whether the signal was delivered.
#[must_use]
pub fn send(pid: i32, signal: i32) -> bool {
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
    /// group already receives a terminal's interrupt, so it only gets SIGTERM.
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
const WATCHED: [i32; 3] = [INT, TERM, HUP];

/// Passes `signal` on to the foreground child.
///
/// The handler registered with `flag::register_usize` already recorded the signal for Luau, so
/// recording it again here would interrupt a cleanup that runs after the first interrupt.
fn on_signal(signal: i32) {
    let pid = FOREGROUND_PID.load(Ordering::SeqCst);
    if pid > 0 {
        forward(pid, FOREGROUND_OWN_GROUP.load(Ordering::SeqCst), signal);
    }
}

/// Passes `signal` on to child `pid`, to its whole group when it leads one.
///
/// A child in dev's own group already receives a terminal's interrupt, so it only gets TERM.
fn forward(pid: i32, own_group: bool, signal: i32) {
    if own_group {
        let _ = send(-pid, signal);
    } else if signal == TERM {
        let _ = send(pid, signal);
    }
}

/// Passes the interrupt that is pending on to child `pid`.
pub fn forward_pending(pid: i32, own_group: bool) {
    forward(
        pid,
        own_group,
        runtime::interrupt_code() - runtime::SIGNAL_EXIT_BASE,
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
        "USR1" => Signal::USR1.as_raw(),
        "USR2" => Signal::USR2.as_raw(),
        "CONT" => Signal::CONT.as_raw(),
        "STOP" => Signal::STOP.as_raw(),
        _ => return None,
    })
}

/// Returns whether the process was started with `signal` ignored.
///
/// Only Linux says so, through /proc. Elsewhere no signal counts as ignored.
fn is_ignored(signal: i32) -> bool {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("SigIgn:"))
                .and_then(|mask| u64::from_str_radix(mask.trim(), 16).ok())
        })
        .is_some_and(|mask| (mask >> (signal - 1)) & 1 == 1)
}

/// Installs the handlers that turn SIGINT, SIGTERM and SIGHUP into a Luau interrupt.
///
/// A SIGINT or SIGHUP that was ignored at start, as `nohup` leaves it, stays ignored where
/// the process can read that (Linux). SIGTERM is always handled.
pub fn install() {
    let handled: Vec<i32> = WATCHED
        .into_iter()
        .filter(|&signal| signal == TERM || !is_ignored(signal))
        .collect();
    for &signal in &handled {
        let slot = runtime::interrupt_slot();
        let _ = flag::register_usize(signal, slot, usize::try_from(signal).unwrap_or(1));
    }
    let Ok(mut signals) = Signals::new(handled) else {
        return;
    };
    thread::spawn(move || {
        for signal in signals.forever() {
            on_signal(signal);
        }
    });
}

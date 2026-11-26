use std::fs::{File, OpenOptions};
use std::time::{Duration, Instant};
use std::{io, thread};

use fs4::fs_std::FileExt;
use mlua::{Lua, MetaMethod, Table, UserData, UserDataMethods};

use crate::native::mode;
use crate::{luau, luau_handle, native_fn, native_struct, runtime};

/// Name of this module under `dev`.
pub const NAME: &str = "lock";

/// Pause between attempts while waiting for a lock with a timeout.
const POLL: Duration = Duration::from_millis(25);

/// Permission bits of a lock file made without a mode, before the umask.
const DEFAULT_MODE: u32 = 0o666;

native_struct! {
    /// Options of `lock` and `try_lock`.
    pub struct LockOptions {
        /// Take a shared lock instead of an exclusive one.
        pub shared: Option<bool>,
        /// Seconds to wait before giving up, forever when missing.
        pub timeout: Option<f64>,
        /// Permission bits of the lock file when it is created.
        pub mode: Option<u32>,
    }
}

/// A held lock, which the file's descriptor carries until it is released or collected.
#[derive(Debug)]
pub struct Handle {
    /// The locked file, `None` once released.
    file: Option<File>,
}

luau_handle!(Handle, "Lock");

impl UserData for Handle {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("release", |_, handle, ()| {
            if let Some(file) = handle.file.take() {
                drop(FileExt::unlock(&file));
            }
            Ok(())
        });
        methods.add_meta_method(MetaMethod::ToString, |_, _, ()| Ok("dev.lock handle"));
    }
}

/// Creates the `dev.lock` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    lock::register(lua, NAME, &table)?;
    try_lock::register(lua, NAME, &table)?;
    luau::value(
        "Lock",
        "release",
        "(self: Lock) -> ()".to_owned(),
        "Releases the lock, and does nothing when it is already released.",
    );
    Ok(table)
}

/// Returns the text of an I/O error without Rust's `(os error N)` tail.
fn message(error: &io::Error) -> String {
    let text = error.to_string();
    match text.rfind(" (os error ") {
        Some(end) => text[..end].to_owned(),
        None => text,
    }
}

/// How long to wait for a lock.
#[derive(Clone, Copy, Debug)]
enum Wait {
    /// Fail at once when the lock is held.
    Never,
    /// Fail after this long.
    Until(Duration),
    /// Keep trying until the lock is free.
    Forever,
}

/// Opens the lock file, creating it with `mode`.
fn open_lock_file(path: &str, mode: Option<u32>) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create_new(true);
    let created = mode::create_with(&mut options, mode.unwrap_or(DEFAULT_MODE)).open(path);
    match created {
        Ok(file) => {
            if let Some(mode) = mode {
                mode::set_file_mode(&file, mode)?;
            }
            Ok(file)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            OpenOptions::new().read(true).write(true).open(path)
        }
        Err(error) => Err(error),
    }
}

/// Tries once to lock `file`, returning whether it is now held.
fn attempt(file: &File, shared: bool) -> io::Result<bool> {
    if shared {
        FileExt::try_lock_shared(file)
    } else {
        FileExt::try_lock_exclusive(file)
    }
}

/// Takes the lock on `path`, or returns why not. It polls, so an interrupt ends the wait.
fn acquire(path: &str, shared: bool, wait: Wait, mode: Option<u32>) -> crate::Result<File> {
    let file = open_lock_file(path, mode)
        .map_err(|error| crate::Error::Message(format!("{path}: {}", message(&error))))?;
    let failed = |error: io::Error| {
        crate::Error::Message(format!("cannot lock {path}: {}", message(&error)))
    };
    let deadline = match wait {
        Wait::Until(limit) => Some(Instant::now() + limit),
        Wait::Never | Wait::Forever => None,
    };
    loop {
        if attempt(&file, shared).map_err(failed)? {
            return Ok(file);
        }
        if matches!(wait, Wait::Never) {
            return Err(crate::Error::Message(format!("the lock on {path} is held")));
        }
        if runtime::interrupted() {
            return Err(crate::Error::Message(
                runtime::INTERRUPTED_MESSAGE.to_owned(),
            ));
        }
        let left = deadline.map(|limit| limit.saturating_duration_since(Instant::now()));
        if left.is_some_and(|left| left.is_zero()) {
            return Err(crate::Error::Message(format!(
                "timed out waiting for the lock on {path}"
            )));
        }
        thread::sleep(left.map_or(POLL, |left| POLL.min(left)));
    }
}

/// Wraps an acquired lock for Luau, raising a pending interrupt instead of a reason.
fn handle_for(outcome: crate::Result<File>) -> mlua::Result<Result<Handle, String>> {
    match outcome {
        Ok(file) => Ok(Ok(Handle { file: Some(file) })),
        Err(error) => {
            runtime::check_interrupt()?;
            Ok(Err(error.to_string()))
        }
    }
}

/// Turns a timeout in seconds into a wait, refusing a negative or invalid one.
fn wait_for(timeout: Option<f64>) -> crate::Result<Wait> {
    match timeout {
        None => Ok(Wait::Forever),
        Some(seconds) if seconds.is_finite() && seconds >= 0.0 => {
            Ok(Wait::Until(Duration::from_secs_f64(seconds)))
        }
        Some(_) => Err(crate::Error::Message(
            "bad argument #2 to 'lock' (timeout must be a number of seconds, 0 or more)".to_owned(),
        )),
    }
}

native_fn! {
    /// Takes a lock on a file, waiting up to `timeout` seconds, and returns a handle whose
    /// `release` method frees it. The lock also frees when the handle is collected or dev exits.
    pub fn lock(
        _lua: &Lua,
        path: String,
        opts: Option<LockOptions>,
    ) -> mlua::Result<Result<Handle, String>> {
        let (shared, timeout, mode) = opts.map_or((false, None, None), |opts| {
            (opts.shared.unwrap_or(false), opts.timeout, opts.mode)
        });
        let wait = wait_for(timeout)?;
        handle_for(acquire(&path, shared, wait, mode))
    }
}

native_fn! {
    /// Takes a lock on a file if it is free, and returns at once with a handle or the reason.
    pub fn try_lock(
        _lua: &Lua,
        path: String,
        opts: Option<LockOptions>,
    ) -> mlua::Result<Result<Handle, String>> {
        let (shared, mode) = opts.map_or((false, None), |opts| {
            (opts.shared.unwrap_or(false), opts.mode)
        });
        handle_for(acquire(&path, shared, Wait::Never, mode))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use super::*;

    /// Returns a lock file path that does not exist yet.
    fn lock_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("dev-lock-test-{tag}-{}", std::process::id()))
    }

    #[test]
    fn acquire_should_refuse_a_held_exclusive_lock() {
        let path = lock_path("held");
        let path_text = path.to_string_lossy().into_owned();
        let held = acquire(&path_text, false, Wait::Never, Some(0o600)).unwrap();
        let second = acquire(&path_text, false, Wait::Never, None);
        assert!(second.unwrap_err().to_string().contains("is held"));
        drop(held);
        assert!(acquire(&path_text, false, Wait::Never, None).is_ok());
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn acquire_should_share_shared_locks() {
        let path = lock_path("shared");
        let path_text = path.to_string_lossy().into_owned();
        let first = acquire(&path_text, true, Wait::Never, None).unwrap();
        assert!(acquire(&path_text, true, Wait::Never, None).is_ok());
        assert!(acquire(&path_text, false, Wait::Never, None).is_err());
        drop(first);
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn acquire_should_give_up_at_the_timeout() {
        let path = lock_path("timeout");
        let path_text = path.to_string_lossy().into_owned();
        let held = acquire(&path_text, false, Wait::Never, None).unwrap();
        let started = Instant::now();
        let outcome = acquire(
            &path_text,
            false,
            Wait::Until(Duration::from_millis(100)),
            None,
        );
        assert!(
            outcome
                .unwrap_err()
                .to_string()
                .starts_with("timed out waiting")
        );
        assert!(started.elapsed() >= Duration::from_millis(100));
        drop(held);
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn open_lock_file_should_apply_the_mode_to_a_new_file() {
        let path = lock_path("mode");
        let path_text = path.to_string_lossy().into_owned();
        drop(open_lock_file(&path_text, Some(0o600)).unwrap());
        if cfg!(unix) {
            assert_eq!(mode::mode_of(&fs::metadata(&path).unwrap()) & 0o777, 0o600);
        }
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn wait_for_should_refuse_a_negative_timeout() {
        assert!(wait_for(Some(-1.0)).is_err());
        assert!(matches!(wait_for(None), Ok(Wait::Forever)));
    }
}

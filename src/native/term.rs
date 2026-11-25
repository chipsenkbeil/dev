use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, IsTerminal, Write};
use std::ops::RangeInclusive;
use std::result::Result as StdResult;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once, PoisonError};
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::terminal;
use mlua::{Function, Lua, LuaString, Table};

use crate::native::pager;
use crate::{native_fn, runtime};

/// Name of this module under `dev`.
pub const NAME: &str = "term";

/// Path of the controlling terminal.
#[cfg(unix)]
const TTY_PATH: &str = "/dev/tty";

/// Path of the console's output buffer, the only part of the controlling terminal dev opens.
#[cfg(windows)]
const TTY_PATH: &str = "CONOUT$";

/// Rows `size` reports when the terminal gives none.
const DEFAULT_ROWS: i64 = 24;

/// Columns `size` reports when the terminal gives none.
const DEFAULT_COLS: i64 = 80;

/// Final bytes of a CSI sequence.
pub const CSI_FINAL: RangeInclusive<u8> = 0x40..=0x7e;

/// Escape text that shows the cursor.
pub const CURSOR_SHOW: &str = "\x1b[?25h";

/// Escape text that hides the cursor.
pub const CURSOR_HIDE: &str = "\x1b[?25l";

/// Escape text that erases the cursor's whole line.
pub const ERASE_LINE: &str = "\x1b[2K";

/// Returns the escape text that moves the cursor to the 1-based `row` and `col`.
#[must_use]
pub fn cursor_to(row: i64, col: i64) -> String {
    format!("\x1b[{};{}H", row.max(1), col.max(1))
}

/// Lowest printable ASCII byte after the space, which has a name of its own.
const PRINTABLE_MIN: u8 = 0x21;

/// Highest printable ASCII byte.
const PRINTABLE_MAX: u8 = 0x7e;

/// Lowest byte that starts a multi-byte UTF-8 character.
const UTF8_LEAD_MIN: u8 = 0xc0;

/// Escape byte.
const ESC: u8 = 0x1b;

/// Escape text that switches to the alternate screen and hides the cursor.
pub const ENTER_ALT: &str = "\x1b[?1049h\x1b[?25l";

/// Escape text that leaves the alternate screen and shows the cursor.
pub const LEAVE_ALT: &str = "\x1b[?1049l\x1b[?25h";

/// Key names `read_key` and `decode` return, as `(constant, name)` pairs.
const KEYS: [(&str, &str); 12] = [
    ("UP", "up"),
    ("DOWN", "down"),
    ("ENTER", "enter"),
    ("ESC", "esc"),
    ("CTRL_C", "ctrl-c"),
    ("SPACE", "space"),
    ("PGUP", "pgup"),
    ("PGDN", "pgdn"),
    ("HOME", "home"),
    ("END", "end"),
    ("EOF", "eof"),
    ("BACKSPACE", "backspace"),
];

/// Terminals `open_tty` opened, by descriptor.
static HANDLES: Mutex<Option<HashMap<i32, File>>> = Mutex::new(None);

/// Key names read ahead of the one `read_key` returned, the next one last.
static QUEUED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Whether this process put the terminal in raw mode.
static RAW: AtomicBool = AtomicBool::new(false);

/// Whether this process switched to the alternate screen.
static ALT: AtomicBool = AtomicBool::new(false);

/// Installs the panic hook once.
static HOOK: Once = Once::new();

/// Returns the name of the key that stands for the bytes after `ESC`, `None` when unknown.
#[must_use]
fn escape_key(tail: &[u8]) -> Option<&'static str> {
    match tail {
        b"[A" | b"OA" => Some("up"),
        b"[B" | b"OB" => Some("down"),
        b"[5~" => Some("pgup"),
        b"[6~" => Some("pgdn"),
        b"[H" | b"OH" | b"[1~" | b"[7~" => Some("home"),
        b"[F" | b"OF" | b"[4~" | b"[8~" => Some("end"),
        _ => None,
    }
}

/// Returns how many bytes after the `ESC` at `start` belong to its sequence, 0 for a lone `ESC`.
#[must_use]
fn escape_length(bytes: &[u8], start: usize) -> usize {
    match bytes.get(start + 1) {
        Some(b'O') => 2,
        Some(b'[') => bytes
            .iter()
            .enumerate()
            .skip(start + 2)
            .find(|(_, byte)| CSI_FINAL.contains(byte))
            .map_or(bytes.len() - start - 1, |(at, _)| at - start),
        _ => 0,
    }
}

/// Returns how many bytes the UTF-8 character that starts with `lead` takes.
#[must_use]
fn utf8_length(lead: u8) -> usize {
    match lead {
        0xf0.. => 4,
        0xe0.. => 3,
        _ => 2,
    }
}

/// Turns raw terminal bytes into key names.
///
/// An unknown escape sequence is skipped and any other printable byte is its own name.
#[must_use]
pub fn decode_bytes(bytes: &[u8]) -> Vec<String> {
    let mut keys = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        let byte = bytes[at];
        if byte == ESC {
            let length = escape_length(bytes, at);
            if length == 0 {
                keys.push("esc".to_owned());
                at += 1;
                continue;
            }
            let end = (at + length + 1).min(bytes.len());
            if let Some(key) = escape_key(&bytes[at + 1..end]) {
                keys.push(key.to_owned());
            }
            at += length + 1;
            continue;
        }
        if byte >= UTF8_LEAD_MIN {
            let length = utf8_length(byte);
            let end = (at + length).min(bytes.len());
            if let Ok(text) = std::str::from_utf8(&bytes[at..end]) {
                keys.push(text.to_owned());
                at = end;
            } else {
                at += 1;
            }
            continue;
        }
        let key = match byte {
            b'\r' | b'\n' => Some("enter".to_owned()),
            3 => Some("ctrl-c".to_owned()),
            16 | b'k' => Some("up".to_owned()),
            14 | b'j' => Some("down".to_owned()),
            b' ' => Some("space".to_owned()),
            PRINTABLE_MIN..=PRINTABLE_MAX => Some(char::from(byte).to_string()),
            _ => None,
        };
        keys.extend(key);
        at += 1;
    }
    keys
}

/// Returns the name `read_key` gives a key event, `None` for a key it does not name.
#[must_use]
pub fn key_name(key: KeyEvent) -> Option<String> {
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let name = match key.code {
        KeyCode::Char('c') if control => "ctrl-c".to_owned(),
        KeyCode::Char('p') if control => "up".to_owned(),
        KeyCode::Char('n') if control => "down".to_owned(),
        KeyCode::Char(_) if control => return None,
        KeyCode::Char(' ') => "space".to_owned(),
        KeyCode::Char('k') => "up".to_owned(),
        KeyCode::Char('j') => "down".to_owned(),
        KeyCode::Char(other) => other.to_string(),
        KeyCode::Up => "up".to_owned(),
        KeyCode::Down => "down".to_owned(),
        KeyCode::Enter => "enter".to_owned(),
        KeyCode::Esc => "esc".to_owned(),
        KeyCode::PageUp => "pgup".to_owned(),
        KeyCode::PageDown => "pgdn".to_owned(),
        KeyCode::Home => "home".to_owned(),
        KeyCode::End => "end".to_owned(),
        KeyCode::Backspace => "backspace".to_owned(),
        _ => return None,
    };
    Some(name)
}

/// Wraps an error from the core's Luau-facing helpers as the crate error.
#[must_use]
pub fn core_error(error: mlua::Error) -> crate::Error {
    crate::Error::Message(runtime::message(&error))
}

/// Writes `bytes` to the shared standard output.
///
/// # Errors
///
/// Returns the failure to write.
pub fn put(lua: &Lua, bytes: &[u8]) -> crate::Result<()> {
    runtime::write_out(lua, bytes).map_err(core_error)
}

/// Flushes the shared standard output.
///
/// # Errors
///
/// Returns the failure to flush.
pub fn flush(lua: &Lua) -> crate::Result<()> {
    runtime::flush_out(lua).map_err(core_error)
}

/// Runs `body` on the table of open terminals.
fn with_handles<T>(body: impl FnOnce(&mut HashMap<i32, File>) -> T) -> T {
    let mut guard = HANDLES.lock().unwrap_or_else(PoisonError::into_inner);
    body(guard.get_or_insert_with(HashMap::new))
}

/// Writes `bytes` to the terminal `fd` names: standard output, standard error or an open handle.
fn write_fd(lua: &Lua, fd: i64, bytes: &[u8]) -> crate::Result<()> {
    match fd {
        1 => put(lua, bytes),
        2 => {
            runtime::write_err(bytes);
            Ok(())
        }
        _ => with_handles(|handles| {
            let key = i32::try_from(fd).unwrap_or(-1);
            match handles.get_mut(&key) {
                Some(file) => file.write_all(bytes).and_then(|()| file.flush()),
                None => Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "not an open terminal",
                )),
            }
            .map_err(|error| crate::Error::io("write to the terminal", error))
        }),
    }
}

/// Tells whether `fd` is a terminal: a standard stream or an open handle.
#[must_use]
fn is_terminal(fd: i64) -> bool {
    match fd {
        0 => io::stdin().is_terminal(),
        1 => io::stdout().is_terminal(),
        2 => io::stderr().is_terminal(),
        _ => with_handles(|handles| {
            i32::try_from(fd)
                .ok()
                .and_then(|key| handles.get(&key))
                .is_some_and(File::is_terminal)
        }),
    }
}

/// Writes `bytes` straight to the controlling terminal, ignoring a failure.
fn write_tty(bytes: &[u8]) {
    if let Ok(mut tty) = OpenOptions::new().write(true).open(TTY_PATH) {
        // The terminal may be gone already and there is nothing left to tell
        let _ = tty.write_all(bytes);
        let _ = tty.flush();
    }
}

/// Puts the terminal in raw mode unless this process already did, returning whether it did.
///
/// # Errors
///
/// Returns the failure to change the terminal's mode.
pub fn enter_raw() -> crate::Result<bool> {
    if RAW.swap(true, Ordering::SeqCst) {
        return Ok(false);
    }
    install_hook();
    terminal::enable_raw_mode().map_err(|error| {
        RAW.store(false, Ordering::SeqCst);
        crate::Error::io("put the terminal in raw mode", error)
    })?;
    Ok(true)
}

/// Returns the terminal to cooked mode when this process put it in raw mode.
pub fn leave_raw() {
    if RAW.swap(false, Ordering::SeqCst) {
        // A terminal that cannot be restored has nothing left to do with it
        let _ = terminal::disable_raw_mode();
    }
}

/// Remembers that the alternate screen is on, so a restore leaves it.
pub fn enter_alt() {
    ALT.store(true, Ordering::SeqCst);
    install_hook();
}

/// Leaves the alternate screen when this process entered it.
pub fn leave_alt() {
    if ALT.swap(false, Ordering::SeqCst) {
        write_tty(LEAVE_ALT.as_bytes());
    }
}

/// Puts the terminal back as it was: leaves the alternate screen, then raw mode.
pub fn restore() {
    leave_alt();
    leave_raw();
}

/// Makes a panic restore the terminal before the default report, once.
fn install_hook() {
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore();
            previous(info);
        }));
    });
}

/// Measures the terminal as `(rows, cols)`, 24 by 80 when it gives none.
#[must_use]
pub fn measure() -> (i64, i64) {
    match terminal::size() {
        Ok((cols, rows)) if cols > 0 && rows > 0 => (i64::from(rows), i64::from(cols)),
        _ => (DEFAULT_ROWS, DEFAULT_COLS),
    }
}

/// How long a read waits for the terminal before it looks for an interrupt.
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Reads the next terminal event, `None` when the terminal closed or failed.
///
/// # Errors
///
/// Returns the interrupt error when a signal arrives while it waits.
pub fn next_event() -> crate::Result<Option<Event>> {
    loop {
        runtime::check_interrupt().map_err(core_error)?;
        match event::poll(POLL_INTERVAL) {
            Ok(true) => return Ok(event::read().ok()),
            Ok(false) => {}
            Err(_) => return Ok(None),
        }
    }
}

/// Returns the key press inside `event`, ignoring releases and every other event.
#[must_use]
fn accepted(event: Event) -> Option<KeyEvent> {
    match event {
        Event::Key(key) if key.kind != KeyEventKind::Release => Some(key),
        _ => None,
    }
}

/// Returns the name of the character in an Alt chord, which terminals send as an escape and then it.
#[must_use]
fn alt_char(key: KeyEvent) -> Option<String> {
    if !key.modifiers.contains(KeyModifiers::ALT) || !matches!(key.code, KeyCode::Char(_)) {
        return None;
    }
    key_name(KeyEvent::new(key.code, key.modifiers - KeyModifiers::ALT))
}

/// Reads the next key a user presses, `None` when the terminal closed or failed.
///
/// # Errors
///
/// Returns the interrupt error when a signal arrives while it waits.
pub fn next_key() -> crate::Result<Option<KeyEvent>> {
    loop {
        let Some(event) = next_event()? else {
            return Ok(None);
        };
        if let Some(key) = accepted(event) {
            return Ok(Some(key));
        }
    }
}

/// Returns the number that names the open terminal `file`: its descriptor.
#[cfg(unix)]
fn handle_key(file: &File) -> i32 {
    use std::os::fd::AsRawFd;

    file.as_raw_fd()
}

/// Returns the number that names the open terminal `file`: the next of a counter, since a
/// Windows handle is no small integer.
#[cfg(windows)]
fn handle_key(_file: &File) -> i32 {
    static NEXT: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(1000);
    NEXT.fetch_add(1, Ordering::SeqCst)
}

/// Runs `body` on the terminal `fd` names, `None` when it is neither a standard stream nor a handle.
#[cfg(unix)]
fn with_fd<T>(fd: i64, body: impl FnOnce(std::os::fd::BorrowedFd<'_>) -> T) -> Option<T> {
    use std::os::fd::AsFd;

    match fd {
        0 => Some(body(rustix::stdio::stdin())),
        1 => Some(body(rustix::stdio::stdout())),
        2 => Some(body(rustix::stdio::stderr())),
        _ => with_handles(|handles| {
            let key = i32::try_from(fd).ok()?;
            handles.get(&key).map(|file| body(file.as_fd()))
        }),
    }
}

/// Reads the settings of the terminal on `fd`, `None` when it has none.
#[cfg(unix)]
#[must_use]
fn get_termios(fd: i64) -> Option<rustix::termios::Termios> {
    with_fd(fd, |terminal| rustix::termios::tcgetattr(terminal).ok()).flatten()
}

/// Applies `settings` to the terminal on `fd`, returning whether that worked.
#[cfg(unix)]
fn set_termios(fd: i64, settings: &rustix::termios::Termios) -> bool {
    use rustix::termios::{OptionalActions, tcsetattr};

    with_fd(fd, |terminal| {
        tcsetattr(terminal, OptionalActions::Now, settings).is_ok()
    })
    .unwrap_or(false)
}

/// Makes a function that runs `action` the first time it is called and does nothing after.
fn once(lua: &Lua, action: impl Fn() + Send + 'static) -> mlua::Result<Function> {
    let done = Arc::new(AtomicBool::new(false));
    lua.create_function(move |_, ()| {
        if !done.swap(true, Ordering::SeqCst) {
            action();
        }
        Ok(())
    })
}

native_fn! {
    /// Opens the controlling terminal for reading and writing, not inherited by children.
    ///
    /// # Errors
    ///
    /// Never fails; no terminal is a `nil` and a reason. On Windows the handle is the console's
    /// output buffer, and its number is made up.
    pub fn open_tty(_lua: &Lua) -> mlua::Result<StdResult<i64, String>> {
        let file = OpenOptions::new().read(true).write(true).open(TTY_PATH);
        Ok(match file {
            Ok(file) => {
                let fd = handle_key(&file);
                with_handles(|handles| handles.insert(fd, file));
                Ok(i64::from(fd))
            }
            Err(error) => Err(crate::Error::io("open the controlling terminal", error).to_string()),
        })
    }
}

native_fn! {
    /// Closes a terminal handle from `open_tty`.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn close(_lua: &Lua, fd: i64) -> mlua::Result<()> {
        if let Ok(key) = i32::try_from(fd) {
            with_handles(|handles| handles.remove(&key));
        }
        Ok(())
    }
}

native_fn! {
    /// Writes `text` to the terminal `fd`: a handle from `open_tty`, or 1 or 2.
    ///
    /// # Errors
    ///
    /// Raises when the standard output buffer fails; any other failure is `nil` and a reason.
    pub fn write(lua: &Lua, fd: i64, text: LuaString) -> mlua::Result<StdResult<(), String>> {
        Ok(write_fd(lua, fd, &text.as_bytes()).map_err(|error| error.to_string()))
    }
}

native_fn! {
    /// Measures the controlling terminal as rows and columns, 24 and 80 when unknown.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn size(_lua: &Lua) -> mlua::Result<(i64, i64)> {
        Ok(measure())
    }
}

native_fn! {
    /// Turns raw terminal bytes into key names, skipping an unknown escape sequence.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn decode(_lua: &Lua, bytes: LuaString) -> mlua::Result<Vec<String>> {
        Ok(decode_bytes(&bytes.as_bytes()))
    }
}

native_fn! {
    /// Blocks until a key arrives and returns its name, `eof` when the terminal closed.
    ///
    /// The terminal must be in raw mode, as `raw` leaves it.
    ///
    /// # Errors
    ///
    /// Never fails.
    pub fn read_key(_lua: &Lua, _fd: i64) -> mlua::Result<String> {
        if let Some(name) = QUEUED.lock().unwrap_or_else(PoisonError::into_inner).pop() {
            return Ok(name);
        }
        loop {
            let Some(key) = next_key()? else {
                return Ok("eof".to_owned());
            };
            if let Some(name) = alt_char(key) {
                QUEUED.lock().unwrap_or_else(PoisonError::into_inner).push(name);
                return Ok("esc".to_owned());
            }
            if let Some(name) = key_name(key) {
                return Ok(name);
            }
        }
    }
}

/// What a key press does to the line being typed.
#[derive(Debug, PartialEq, Eq)]
enum LineEdit {
    /// Text to echo, which may be empty.
    Echo(Vec<u8>),
    /// The line is complete.
    Done,
    /// The user pressed Ctrl-C.
    Interrupted,
    /// The user pressed Ctrl-D on an empty line.
    Closed,
}

/// Applies `key` to `line` and says what to do next.
#[must_use]
fn edit_line(line: &mut String, key: KeyEvent) -> LineEdit {
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Char('c') if control => LineEdit::Interrupted,
        KeyCode::Char('d') if control && line.is_empty() => LineEdit::Closed,
        KeyCode::Enter => LineEdit::Done,
        KeyCode::Char('j') if control => LineEdit::Done,
        KeyCode::Backspace if line.pop().is_some() => LineEdit::Echo(b"\x08 \x08".to_vec()),
        KeyCode::Char(typed) if !control => {
            line.push(typed);
            LineEdit::Echo(typed.to_string().into_bytes())
        }
        _ => LineEdit::Echo(Vec::new()),
    }
}

/// Reads and echoes one typed line, `Err` with why when it ended without one.
fn type_line(lua: &Lua, fd: i64) -> crate::Result<StdResult<String, &'static str>> {
    let mut line = String::new();
    loop {
        let Some(key) = next_key()? else {
            return Ok(Err("eof"));
        };
        match edit_line(&mut line, key) {
            LineEdit::Echo(bytes) => write_fd(lua, fd, &bytes)?,
            LineEdit::Done => {
                write_fd(lua, fd, b"\r\n")?;
                return Ok(Ok(line));
            }
            LineEdit::Interrupted => {
                write_fd(lua, fd, b"^C")?;
                return Ok(Err("interrupted"));
            }
            LineEdit::Closed => return Ok(Err("eof")),
        }
    }
}

native_fn! {
    /// Reads one line typed on the terminal `fd`, echoing it and honouring backspace.
    ///
    /// Returns `nil, "interrupted"` on Ctrl-C and `nil, "eof"` on Ctrl-D or a closed terminal.
    ///
    /// # Errors
    ///
    /// Raises when the terminal cannot enter raw mode.
    pub fn read_line(lua: &Lua, fd: i64) -> mlua::Result<StdResult<String, String>> {
        let entered = enter_raw()?;
        let outcome = type_line(lua, fd);
        if entered {
            leave_raw();
        }
        Ok(outcome?.map_err(str::to_owned))
    }
}

native_fn! {
    /// Moves the cursor to the 1-based `row` and `col`.
    ///
    /// # Errors
    ///
    /// Raises when the standard output buffer fails.
    pub fn move_to(lua: &Lua, row: i64, col: i64) -> mlua::Result<()> {
        runtime::write_out(lua, cursor_to(row, col).as_bytes())
    }
}

native_fn! {
    /// Clears the screen and moves the cursor to the top left.
    ///
    /// # Errors
    ///
    /// Raises when the standard output buffer fails.
    pub fn clear(lua: &Lua) -> mlua::Result<()> {
        runtime::write_out(lua, b"\x1b[2J\x1b[H")
    }
}

native_fn! {
    /// Switches to the alternate screen when `on` is true and back when it is false.
    ///
    /// The terminal leaves the alternate screen when dev exits.
    ///
    /// # Errors
    ///
    /// Raises when the standard output buffer fails.
    pub fn alt_screen(lua: &Lua, on: bool) -> mlua::Result<()> {
        if on {
            enter_alt();
            runtime::write_out(lua, ENTER_ALT.as_bytes())?;
            runtime::flush_out(lua)
        } else {
            runtime::flush_out(lua)?;
            leave_alt();
            Ok(())
        }
    }
}

native_fn! {
    /// Puts the terminal in raw mode, where each key arrives alone, unechoed and with no signals.
    ///
    /// The function it returns restores the terminal, only the first time it is called.
    ///
    /// # Errors
    ///
    /// Raises when `fd` is not a terminal or cannot change mode.
    #[luau = "(fd: number) -> () -> ()"]
    pub fn raw(lua: &Lua, fd: i64) -> mlua::Result<Function> {
        if !is_terminal(fd) {
            return Err(mlua::Error::runtime(format!("fd {fd} is not a terminal")));
        }
        let entered = enter_raw()?;
        once(lua, move || {
            if entered {
                leave_raw();
            }
        })
    }
}

native_fn! {
    /// Turns off the echo of typed characters on `fd`, keeping line editing and signals.
    ///
    /// The echo also comes back when dev exits. When `fd` is not a terminal the returned
    /// function does nothing, and on Windows it always does nothing, so typed characters echo.
    ///
    /// # Errors
    ///
    /// Raises when the exit cleanup cannot be registered.
    #[luau = "(fd: number) -> () -> ()"]
    pub fn silent(lua: &Lua, fd: i64) -> mlua::Result<Function> {
        #[cfg(windows)]
        {
            let _ = fd;
            once(lua, || {})
        }
        #[cfg(unix)]
        {
            let Some(settings) = get_termios(fd) else {
                return once(lua, || {});
            };
            let mut quiet = settings.clone();
            quiet
                .local_modes
                .remove(rustix::termios::LocalModes::ECHO);
            if !set_termios(fd, &quiet) {
                return once(lua, || {});
            }
            let restore = once(lua, move || {
                set_termios(fd, &settings);
            })?;
            runtime::on_exit(lua, restore.clone())?;
            Ok(restore)
        }
    }
}

/// Creates the `dev.term` module table.
///
/// # Errors
///
/// Returns the Lua error when a function or field cannot be set.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("TTY_PATH", TTY_PATH)?;
    table.set("DEFAULT_COLS", DEFAULT_COLS)?;
    let keys = lua.create_table()?;
    for (constant, name) in KEYS {
        keys.set(constant, name)?;
    }
    table.set("Key", keys)?;
    open_tty::register(lua, NAME, &table)?;
    close::register(lua, NAME, &table)?;
    write::register(lua, NAME, &table)?;
    size::register(lua, NAME, &table)?;
    decode::register(lua, NAME, &table)?;
    read_key::register(lua, NAME, &table)?;
    read_line::register(lua, NAME, &table)?;
    move_to::register(lua, NAME, &table)?;
    clear::register(lua, NAME, &table)?;
    alt_screen::register(lua, NAME, &table)?;
    raw::register(lua, NAME, &table)?;
    silent::register(lua, NAME, &table)?;
    pager::page::register(lua, NAME, &table)?;
    let cleanup = lua.create_function(|_, ()| {
        restore();
        Ok(())
    })?;
    runtime::on_exit(lua, cleanup)?;
    Ok(table)
}

#[cfg(test)]
mod tests {
    use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

    use super::{
        LineEdit, accepted, alt_char, decode_bytes, edit_line, key_name, measure, next_event,
    };
    use crate::runtime;

    #[test]
    fn decode_bytes_should_name_arrows_and_plain_bytes() {
        let keys = decode_bytes(b"\x1b[A\x1bOB q\r\x03");
        assert_eq!(keys, ["up", "down", "space", "q", "enter", "ctrl-c"]);
    }

    #[test]
    fn decode_bytes_should_skip_an_unknown_escape() {
        assert_eq!(decode_bytes(b"\x1b[99Zx"), ["x"]);
        assert_eq!(decode_bytes(b"\x1b"), ["esc"]);
    }

    #[test]
    fn decode_bytes_should_map_paging_keys() {
        let keys = decode_bytes(b"\x1b[5~\x1b[6~\x1b[H\x1b[F\x1b[1~\x1b[4~");
        assert_eq!(keys, ["pgup", "pgdn", "home", "end", "home", "end"]);
    }

    #[test]
    fn decode_bytes_should_map_vi_and_emacs_keys() {
        assert_eq!(decode_bytes(b"kj\x10\x0e"), ["up", "down", "up", "down"]);
    }

    #[test]
    fn key_name_should_name_control_chords() {
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(key_name(ctrl_c).as_deref(), Some("ctrl-c"));
        let ctrl_x = KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL);
        assert_eq!(key_name(ctrl_x), None);
    }

    #[test]
    fn key_name_should_name_plain_keys() {
        let plain = |code| key_name(KeyEvent::new(code, KeyModifiers::NONE));
        assert_eq!(plain(KeyCode::Char('j')).as_deref(), Some("down"));
        assert_eq!(plain(KeyCode::Char('x')).as_deref(), Some("x"));
        assert_eq!(plain(KeyCode::PageUp).as_deref(), Some("pgup"));
        assert_eq!(plain(KeyCode::F(1)), None);
    }

    #[test]
    fn next_event_should_return_the_interrupt_error_when_a_signal_arrived() {
        runtime::interrupt(crate::native::signals::INT);
        let error = next_event().expect_err("the pending interrupt must raise");
        assert!(runtime::is_interrupt(&mlua::Error::from(error)));
    }

    #[test]
    fn measure_should_report_positive_dimensions() {
        let (rows, cols) = measure();
        assert!(rows > 0 && cols > 0);
    }

    #[test]
    fn decode_bytes_should_decode_a_multi_byte_character() {
        assert_eq!(decode_bytes("é".as_bytes()), ["é"]);
        assert_eq!(decode_bytes(b"\xc3"), Vec::<String>::new());
    }

    #[test]
    fn accepted_should_drop_releases_and_other_events() {
        let mut release = KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE);
        release.kind = KeyEventKind::Release;
        assert_eq!(accepted(Event::Key(release)), None);
        assert_eq!(accepted(Event::Resize(80, 24)), None);
        let press = KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE);
        assert_eq!(accepted(Event::Key(press)), Some(press));
    }

    #[test]
    fn alt_char_should_name_the_character_of_an_alt_chord() {
        let chord = KeyEvent::new(KeyCode::Char('x'), KeyModifiers::ALT);
        assert_eq!(alt_char(chord).as_deref(), Some("x"));
        let plain = KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE);
        assert_eq!(alt_char(plain), None);
    }

    #[test]
    fn edit_line_should_type_erase_and_finish() {
        let mut line = String::new();
        let press = |code, modifiers| KeyEvent::new(code, modifiers);
        let none = KeyModifiers::NONE;
        assert_eq!(
            edit_line(&mut line, press(KeyCode::Char('y'), none)),
            LineEdit::Echo(b"y".to_vec())
        );
        assert_eq!(
            edit_line(&mut line, press(KeyCode::Backspace, none)),
            LineEdit::Echo(b"\x08 \x08".to_vec())
        );
        assert_eq!(
            edit_line(&mut line, press(KeyCode::Backspace, none)),
            LineEdit::Echo(Vec::new())
        );
        assert_eq!(
            edit_line(&mut line, press(KeyCode::Enter, none)),
            LineEdit::Done
        );
    }

    #[test]
    fn edit_line_should_finish_on_ctrl_j() {
        let mut line = String::from("y");
        let key = KeyEvent::new(KeyCode::Char('j'), KeyModifiers::CONTROL);
        assert_eq!(edit_line(&mut line, key), LineEdit::Done);
        assert_eq!(line, "y");
    }

    #[test]
    fn edit_line_should_end_on_control_c_and_on_control_d_when_empty() {
        let control = KeyModifiers::CONTROL;
        let mut line = String::new();
        assert_eq!(
            edit_line(&mut line, KeyEvent::new(KeyCode::Char('c'), control)),
            LineEdit::Interrupted
        );
        assert_eq!(
            edit_line(&mut line, KeyEvent::new(KeyCode::Char('d'), control)),
            LineEdit::Closed
        );
        line.push('a');
        assert_eq!(
            edit_line(&mut line, KeyEvent::new(KeyCode::Char('d'), control)),
            LineEdit::Echo(Vec::new())
        );
    }
}

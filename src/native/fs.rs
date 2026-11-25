use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use mlua::{Lua, LuaString, Table, Variadic};

use crate::native::mode;
use crate::{native_fn, native_struct};

/// Name of this module under `dev`.
pub const NAME: &str = "fs";

/// Bytes read from a descriptor per system call.
const READ_CHUNK_BYTES: usize = 65536;

/// File type bits of `st_mode`.
const S_IFMT: u32 = 0o170_000;

/// Regular file bits of `st_mode`.
const S_IFREG: u32 = 0o100_000;

/// Directory bits of `st_mode`.
const S_IFDIR: u32 = 0o040_000;

/// Symbolic link bits of `st_mode`.
const S_IFLNK: u32 = 0o120_000;

/// Characters a temporary name may use.
const NAME_CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Length of the random part of a temporary name.
const NAME_SUFFIX_LEN: usize = 6;

/// Most names tried for one temporary path.
const NAME_ATTEMPTS: usize = 100;

/// Permission bits of a temporary file.
const TEMP_FILE_MODE: u32 = 0o600;

/// Permission bits of a temporary folder.
const TEMP_DIR_MODE: u32 = 0o700;

/// Permission bits of a file made without a given mode, before the umask.
const DEFAULT_FILE_MODE: u32 = 0o666;

/// Counter that keeps temporary names of one process apart.
static COUNTER: AtomicU64 = AtomicU64::new(0);

/// Next number `open_nofollow` hands out where a file has no descriptor of its own.
#[cfg(not(unix))]
static NEXT_DESCRIPTOR: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(3);

/// Descriptors opened by `open_nofollow`, by number, until `close`.
static DESCRIPTORS: Mutex<Option<HashMap<i32, File>>> = Mutex::new(None);

native_struct! {
    /// Owner, mode, size and kind of a path or descriptor.
    pub struct FsStat {
        /// Owner user id.
        pub uid: u32,
        /// Raw st_mode, file type bits included.
        pub mode: u32,
        /// Size in bytes.
        pub size: u64,
        /// What it is: file, dir, link or other.
        pub kind: String,
    }
}

native_struct! {
    /// Options of `write`.
    pub struct WriteOptions {
        /// Permission bits given to the file when it is created.
        pub mode: Option<u32>,
        /// Write a temporary file and rename it over the target.
        pub atomic: Option<bool>,
    }
}

native_struct! {
    /// Options of `mkdir`.
    pub struct MkdirOptions {
        /// Make missing parents and accept an existing folder.
        pub parents: Option<bool>,
    }
}

native_struct! {
    /// Options of `remove`.
    pub struct RemoveOptions {
        /// Remove a folder with its contents and accept a missing path.
        pub recursive: Option<bool>,
    }
}

native_struct! {
    /// Options of `mktemp`.
    pub struct MktempOptions {
        /// Name prefix, `dev` by default.
        pub prefix: Option<String>,
        /// Make a folder instead of a file.
        pub dir: Option<bool>,
    }
}

/// Creates the `dev.fs` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    let kinds = lua.create_table()?;
    kinds.set("FILE", "file")?;
    kinds.set("DIR", "dir")?;
    kinds.set("LINK", "link")?;
    kinds.set("OTHER", "other")?;
    table.set("Kind", kinds)?;
    exists::register(lua, NAME, &table)?;
    is_dir::register(lua, NAME, &table)?;
    is_file::register(lua, NAME, &table)?;
    is_link::register(lua, NAME, &table)?;
    is_exec::register(lua, NAME, &table)?;
    read::register(lua, NAME, &table)?;
    write::register(lua, NAME, &table)?;
    append::register(lua, NAME, &table)?;
    mkdir::register(lua, NAME, &table)?;
    remove::register(lua, NAME, &table)?;
    move_path::register(lua, NAME, &table)?;
    list::register(lua, NAME, &table)?;
    stat::register(lua, NAME, &table)?;
    realpath::register(lua, NAME, &table)?;
    readlink::register(lua, NAME, &table)?;
    mktemp::register(lua, NAME, &table)?;
    symlink::register(lua, NAME, &table)?;
    chmod::register(lua, NAME, &table)?;
    join::register(lua, NAME, &table)?;
    dirname::register(lua, NAME, &table)?;
    basename::register(lua, NAME, &table)?;
    open_nofollow::register(lua, NAME, &table)?;
    fstat::register(lua, NAME, &table)?;
    read_fd::register(lua, NAME, &table)?;
    close::register(lua, NAME, &table)?;
    Ok(table)
}

/// Returns the system's text for `error`, without Rust's `(os error N)` tail.
fn message(error: &io::Error) -> String {
    let text = error.to_string();
    match text.rfind(" (os error ") {
        Some(end) => text[..end].to_owned(),
        None => text,
    }
}

/// Words a failure on `path` the way `io.open` did, as `PATH: MESSAGE`.
fn reason(path: &str, error: &io::Error) -> String {
    format!("{path}: {}", message(error))
}

/// Returns the kind name of a raw `st_mode`.
fn kind_of(mode: u32) -> &'static str {
    match mode & S_IFMT {
        S_IFREG => "file",
        S_IFDIR => "dir",
        S_IFLNK => "link",
        _ => "other",
    }
}

/// Builds the table shape of `stat` from file metadata.
fn stat_of(meta: &fs::Metadata) -> FsStat {
    FsStat {
        uid: mode::owner_of(meta),
        mode: mode::mode_of(meta),
        size: meta.len(),
        kind: kind_of(mode::mode_of(meta)).to_owned(),
    }
}

/// Runs `use_table` on the descriptor table, which is created on first use.
fn with_descriptors<T>(use_table: impl FnOnce(&mut HashMap<i32, File>) -> T) -> T {
    let mut guard = DESCRIPTORS.lock().unwrap_or_else(PoisonError::into_inner);
    use_table(guard.get_or_insert_with(HashMap::new))
}

native_fn! {
    /// Checks that `path` exists, following links.
    pub fn exists(_lua: &Lua, path: String) -> mlua::Result<bool> {
        Ok(fs::metadata(path).is_ok())
    }
}

native_fn! {
    /// Checks that `path` is a directory or a link to one.
    pub fn is_dir(_lua: &Lua, path: String) -> mlua::Result<bool> {
        Ok(fs::metadata(path).is_ok_and(|meta| meta.is_dir()))
    }
}

native_fn! {
    /// Checks that `path` is a regular file or a link to one.
    pub fn is_file(_lua: &Lua, path: String) -> mlua::Result<bool> {
        Ok(fs::metadata(path).is_ok_and(|meta| meta.is_file()))
    }
}

native_fn! {
    /// Checks that `path` is a symbolic link, a broken one included.
    pub fn is_link(_lua: &Lua, path: String) -> mlua::Result<bool> {
        Ok(fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink()))
    }
}

native_fn! {
    /// Checks that the process may execute `path`.
    pub fn is_exec(_lua: &Lua, path: String) -> mlua::Result<bool> {
        Ok(is_runnable(&path))
    }
}

/// Returns whether the process may execute `path`.
#[cfg(unix)]
fn is_runnable(path: &str) -> bool {
    rustix::fs::access(path, rustix::fs::Access::EXEC_OK).is_ok()
}

/// Returns whether `path` is a file whose name ends in one of the `PATHEXT` extensions.
#[cfg(windows)]
fn is_runnable(path: &str) -> bool {
    use crate::native::os;

    fs::metadata(path).is_ok_and(|meta| meta.is_file()) && os::has_pathext(path, &os::pathext())
}

native_fn! {
    /// Reads a whole file, or returns nil and the reason.
    pub fn read(lua: &Lua, path: String) -> mlua::Result<Result<LuaString, String>> {
        match fs::read(&path) {
            Ok(bytes) => Ok(Ok(lua.create_string(bytes)?)),
            Err(error) => Ok(Err(reason(&path, &error))),
        }
    }
}

/// Returns a mapper that words an I/O failure on `path` as `PATH: MESSAGE`.
fn at(path: &Path) -> impl Fn(io::Error) -> crate::Error + '_ {
    move |error| crate::Error::Message(reason(&path.to_string_lossy(), &error))
}

/// Opens `path` for writing and truncates it, applying `mode` when the call creates it.
fn open_for_write(path: &Path, mode: Option<u32>) -> crate::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    let created = mode::create_with(&mut options, mode.unwrap_or(DEFAULT_FILE_MODE)).open(path);
    match created {
        Ok(file) => {
            if let Some(mode) = mode {
                mode::set_file_mode(&file, mode).map_err(at(path))?;
            }
            Ok(file)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(path)
            .map_err(at(path)),
        Err(error) => Err(at(path)(error)),
    }
}

/// Picks a name next to `target` for its temporary copy.
fn sibling_temp(target: &Path) -> PathBuf {
    let name = target.file_name().map_or_else(
        || "dev".to_owned(),
        |name| name.to_string_lossy().into_owned(),
    );
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let stamp = random_suffix(count);
    target.with_file_name(format!(".{name}.{stamp}.tmp"))
}

/// Writes `text` to the new file `temp` and renames it over `path`.
fn fill_and_rename(temp: &Path, path: &Path, text: &[u8], mode: Option<u32>) -> crate::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    let mut file = mode::create_with(&mut options, mode.unwrap_or(DEFAULT_FILE_MODE))
        .open(temp)
        .map_err(at(path))?;
    if let Some(mode) = mode {
        mode::set_file_mode(&file, mode).map_err(at(path))?;
    }
    file.write_all(text).map_err(at(path))?;
    file.sync_all().map_err(at(path))?;
    fs::rename(temp, path).map_err(at(path))
}

/// Returns the permission bits of the file at `path`, which an atomic write keeps.
#[must_use]
#[cfg(unix)]
fn existing_mode(path: &Path) -> Option<u32> {
    fs::metadata(path)
        .ok()
        .map(|meta| mode::mode_of(&meta) & 0o7777)
}

/// Returns no mode, since a read-only flag kept on the copy would stop it replacing the file.
#[must_use]
#[cfg(not(unix))]
fn existing_mode(_path: &Path) -> Option<u32> {
    None
}

/// Writes `text` to a temporary file next to `path` and renames it over `path`.
fn write_atomic(path: &Path, text: &[u8], mode: Option<u32>) -> crate::Result<()> {
    let mode = mode.or_else(|| existing_mode(path));
    let temp = sibling_temp(path);
    let outcome = fill_and_rename(&temp, path, text, mode);
    if outcome.is_err() {
        drop(fs::remove_file(&temp));
    }
    outcome
}

native_fn! {
    /// Writes a whole file, replacing it. `mode` applies when the file is created, and `atomic`
    /// keeps the old file whole when the write fails.
    pub fn write(
        _lua: &Lua,
        path: String,
        text: LuaString,
        opts: Option<WriteOptions>,
    ) -> mlua::Result<Result<bool, String>> {
        let (mode, atomic) = opts.map_or((None, false), |opts| {
            (opts.mode, opts.atomic.unwrap_or(false))
        });
        let bytes = text.as_bytes();
        let target = Path::new(&path);
        let outcome = if atomic {
            write_atomic(target, &bytes, mode)
        } else {
            open_for_write(target, mode)
                .and_then(|mut file| file.write_all(&bytes).map_err(at(target)))
        };
        Ok(outcome.map(|()| true).map_err(|error| error.to_string()))
    }
}

native_fn! {
    /// Appends text to a file, creating it when it is missing.
    pub fn append(_lua: &Lua, path: String, text: LuaString) -> mlua::Result<Result<bool, String>> {
        let bytes = text.as_bytes();
        let outcome = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&path)
            .and_then(|mut file| file.write_all(&bytes));
        Ok(outcome.map(|()| true).map_err(|error| reason(&path, &error)))
    }
}

native_fn! {
    /// Makes a directory. With `parents` it makes missing parents and accepts an existing one.
    pub fn mkdir(
        _lua: &Lua,
        path: String,
        opts: Option<MkdirOptions>,
    ) -> mlua::Result<Result<bool, String>> {
        let parents = opts.and_then(|opts| opts.parents).unwrap_or(false);
        let outcome = if parents {
            fs::create_dir_all(&path)
        } else {
            fs::create_dir(&path)
        };
        Ok(outcome.map(|()| true).map_err(|error| reason(&path, &error)))
    }
}

native_fn! {
    /// Removes a file, link or directory. With `recursive` it removes a folder with its contents
    /// and accepts a missing path.
    pub fn remove(
        _lua: &Lua,
        path: String,
        opts: Option<RemoveOptions>,
    ) -> mlua::Result<Result<bool, String>> {
        let recursive = opts.and_then(|opts| opts.recursive).unwrap_or(false);
        let outcome = match fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_dir() && recursive => fs::remove_dir_all(&path),
            Ok(meta) if meta.is_dir() => {
                return Ok(Err(format!("{path}: Is a directory")));
            }
            Ok(_) => fs::remove_file(&path),
            Err(error) if error.kind() == io::ErrorKind::NotFound && recursive => Ok(()),
            Err(error) => Err(error),
        };
        Ok(outcome.map(|()| true).map_err(|error| reason(&path, &error)))
    }
}

/// Copies a file, link or folder tree from `from` to `to`.
fn copy_tree(from: &Path, to: &Path) -> crate::Result<()> {
    let meta = fs::symlink_metadata(from).map_err(at(from))?;
    if meta.file_type().is_symlink() {
        let target = fs::read_link(from).map_err(at(from))?;
        copy_symlink(&meta, &target, to).map_err(at(to))
    } else if meta.is_dir() {
        fs::create_dir(to).map_err(at(to))?;
        for entry in fs::read_dir(from).map_err(at(from))? {
            let entry = entry.map_err(at(from))?;
            copy_tree(&entry.path(), &to.join(entry.file_name()))?;
        }
        fs::set_permissions(to, meta.permissions()).map_err(at(to))
    } else if meta.is_file() {
        fs::copy(from, to).map(drop).map_err(at(from))
    } else {
        Err(crate::Error::Message(format!(
            "{}: cannot copy a special file",
            from.display()
        )))
    }
}

/// Removes a file, link or folder tree.
fn remove_tree(path: &Path) -> crate::Result<()> {
    let is_dir = fs::symlink_metadata(path).map_err(at(path))?.is_dir();
    if is_dir {
        fs::remove_dir_all(path).map_err(at(path))
    } else {
        fs::remove_file(path).map_err(at(path))
    }
}

native_fn! {
    /// Moves a path to one that does not exist yet, copying across filesystems.
    #[name = "move"]
    pub fn move_path(_lua: &Lua, from: String, to: String) -> mlua::Result<Result<bool, String>> {
        if fs::symlink_metadata(&to).is_ok() {
            return Ok(Err(format!("{to} already exists")));
        }
        let (source, target) = (Path::new(&from), Path::new(&to));
        let outcome = match fs::rename(source, target) {
            Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
                copy_tree(source, target).and_then(|()| remove_tree(source))
            }
            other => other.map_err(at(source)),
        };
        Ok(outcome.map(|()| true).map_err(|error| error.to_string()))
    }
}

native_fn! {
    /// Lists the names in a directory, sorted, hidden names included.
    pub fn list(_lua: &Lua, dir: String) -> mlua::Result<Result<Vec<String>, String>> {
        let Ok(entries) = fs::read_dir(&dir) else {
            return Ok(Err(format!("cannot list {dir}")));
        };
        let mut names = Vec::new();
        for entry in entries {
            match entry {
                Ok(entry) => names.push(entry.file_name().to_string_lossy().into_owned()),
                Err(_) => return Ok(Err(format!("cannot list {dir}"))),
            }
        }
        names.sort();
        Ok(Ok(names))
    }
}

native_fn! {
    /// Reads a path's owner, mode, size and kind without following a link, or nil when missing.
    pub fn stat(_lua: &Lua, path: String) -> mlua::Result<Option<FsStat>> {
        Ok(fs::symlink_metadata(path).ok().map(|meta| stat_of(&meta)))
    }
}

native_fn! {
    /// Resolves `path` to an absolute path with no links.
    pub fn realpath(_lua: &Lua, path: String) -> mlua::Result<Result<String, String>> {
        match canonical(Path::new(&path)) {
            Ok(real) => Ok(Ok(real.to_string_lossy().into_owned())),
            Err(_) => Ok(Err(format!("cannot resolve {path}"))),
        }
    }
}

native_fn! {
    /// Reads where a symbolic link points.
    pub fn readlink(_lua: &Lua, path: String) -> mlua::Result<Result<String, String>> {
        match fs::read_link(&path) {
            Ok(target) => Ok(Ok(target.to_string_lossy().into_owned())),
            Err(_) => Ok(Err(format!("{path} is not a link"))),
        }
    }
}

/// Returns `NAME_SUFFIX_LEN` hard-to-guess characters, seeded by `salt`.
fn random_suffix(salt: u64) -> String {
    use std::hash::{BuildHasher, Hasher, RandomState};

    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u64(salt);
    hasher.write_u32(std::process::id());
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    hasher.write_u128(nanos);
    let mut state = hasher.finish();
    let radix = NAME_CHARS.len() as u64;
    let mut text = String::with_capacity(NAME_SUFFIX_LEN);
    for _ in 0..NAME_SUFFIX_LEN {
        let index = usize::try_from(state % radix).unwrap_or(0);
        text.push(char::from(NAME_CHARS[index]));
        state /= radix;
    }
    text
}

native_fn! {
    /// Makes a temporary file or directory named PREFIX.XXXXXX under TMPDIR, else /tmp.
    pub fn mktemp(
        _lua: &Lua,
        opts: Option<MktempOptions>,
    ) -> mlua::Result<Result<String, String>> {
        let (prefix, dir) = opts.map_or((None, false), |opts| {
            (opts.prefix, opts.dir.unwrap_or(false))
        });
        let prefix = prefix.unwrap_or_else(|| "dev".to_owned());
        let tmpdir = std::env::var("TMPDIR").unwrap_or_else(|_| default_tmpdir());
        let base = tmpdir.trim_end_matches('/').to_owned();
        for _ in 0..NAME_ATTEMPTS {
            let count = COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = format!("{base}/{prefix}.{}", random_suffix(count));
            let made = if dir {
                mode::create_dir_with(Path::new(&path), TEMP_DIR_MODE)
            } else {
                let mut options = OpenOptions::new();
                options.write(true).create_new(true);
                mode::create_with(&mut options, TEMP_FILE_MODE)
                    .open(&path)
                    .map(drop)
            };
            match made {
                Ok(()) => return Ok(Ok(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => break,
            }
        }
        Ok(Err(format!("cannot make a temporary path under {base}")))
    }
}

native_fn! {
    /// Makes a symbolic link at `link` holding `target`.
    pub fn symlink(_lua: &Lua, target: String, link: String) -> mlua::Result<Result<bool, String>> {
        let outcome = make_symlink(Path::new(&target), Path::new(&link));
        Ok(outcome.map(|()| true).map_err(|error| reason(&link, &error)))
    }
}

/// Returns the folder `mktemp` uses when `TMPDIR` is unset.
#[must_use]
#[cfg(unix)]
fn default_tmpdir() -> String {
    "/tmp".to_owned()
}

/// Returns the folder `mktemp` uses when `TMPDIR` is unset.
#[must_use]
#[cfg(not(unix))]
fn default_tmpdir() -> String {
    std::env::temp_dir().to_string_lossy().into_owned()
}

/// Makes a symbolic link at `link` holding `target`.
#[cfg(unix)]
fn make_symlink(target: &Path, link: &Path) -> io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

/// Makes a symbolic link at `link` holding `target`, of the kind its target is.
#[cfg(windows)]
fn make_symlink(target: &Path, link: &Path) -> io::Result<()> {
    let resolved = link
        .parent()
        .map_or_else(|| target.to_path_buf(), |parent| parent.join(target));
    if resolved.is_dir() {
        std::os::windows::fs::symlink_dir(target, link)
    } else {
        std::os::windows::fs::symlink_file(target, link)
    }
}

/// Copies the symbolic link `source` describes to `link`, holding `target`.
#[cfg(unix)]
fn copy_symlink(_source: &fs::Metadata, target: &Path, link: &Path) -> io::Result<()> {
    make_symlink(target, link)
}

/// Copies the symbolic link `source` describes to `link`, of the kind the original is.
#[cfg(windows)]
fn copy_symlink(source: &fs::Metadata, target: &Path, link: &Path) -> io::Result<()> {
    use std::os::windows::fs::FileTypeExt;

    if source.file_type().is_symlink_dir() {
        std::os::windows::fs::symlink_dir(target, link)
    } else {
        std::os::windows::fs::symlink_file(target, link)
    }
}

/// Resolves `path` to an absolute path with no links and no verbatim prefix.
///
/// # Errors
///
/// Returns the error of the system call that resolves it.
pub fn canonical(path: &Path) -> io::Result<PathBuf> {
    let real = fs::canonicalize(path)?;
    Ok(match real.to_str().and_then(strip_verbatim) {
        Some(plain) => PathBuf::from(plain),
        None => real,
    })
}

/// Returns `path` without its `\\?\` prefix, or `None` when it has none.
#[must_use]
fn strip_verbatim(path: &str) -> Option<String> {
    let rest = path.strip_prefix(r"\\?\")?;
    if let Some(share) = rest.strip_prefix(r"UNC\") {
        return Some(format!(r"\\{share}"));
    }
    let mut chars = rest.chars();
    let on_drive = chars
        .next()
        .is_some_and(|letter| letter.is_ascii_alphabetic())
        && chars.next() == Some(':');
    on_drive.then(|| rest.to_owned())
}

native_fn! {
    /// Sets the permission bits of `path`.
    pub fn chmod(_lua: &Lua, path: String, mode: u32) -> mlua::Result<Result<bool, String>> {
        let outcome = mode::set_path_mode(Path::new(&path), mode);
        Ok(outcome.map(|()| true).map_err(|error| reason(&path, &error)))
    }
}

/// Joins parts with single slashes.
fn join_parts(parts: &[String]) -> String {
    let joined = parts.join("/");
    let mut text = String::with_capacity(joined.len());
    let mut previous_slash = false;
    for ch in joined.chars() {
        if ch == '/' && previous_slash {
            continue;
        }
        previous_slash = ch == '/';
        text.push(ch);
    }
    text
}

/// Takes the directory part of `path`.
fn dir_part(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        let root = path.starts_with('/');
        return String::from(if root { "/" } else { "." });
    }
    let Some(end) = trimmed.rfind('/') else {
        return ".".to_owned();
    };
    let dir = trimmed[..end].trim_end_matches('/');
    String::from(if dir.is_empty() { "/" } else { dir })
}

/// Takes the last part of `path`.
fn base_part(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        let root = path.starts_with('/');
        return String::from(if root { "/" } else { "" });
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed).to_owned()
}

native_fn! {
    /// Joins path parts with single slashes.
    pub fn join(_lua: &Lua, parts: Variadic<String>) -> mlua::Result<String> {
        Ok(join_parts(&parts))
    }
}

native_fn! {
    /// Takes the directory part of a path, `.` when it has none.
    pub fn dirname(_lua: &Lua, path: String) -> mlua::Result<String> {
        Ok(dir_part(&path))
    }
}

native_fn! {
    /// Takes the last part of a path, `/` for the root.
    pub fn basename(_lua: &Lua, path: String) -> mlua::Result<String> {
        Ok(base_part(&path))
    }
}

native_fn! {
    /// Opens `path` for reading, refusing a symbolic link in its last part, without blocking.
    pub fn open_nofollow(_lua: &Lua, path: String) -> mlua::Result<Result<i32, String>> {
        if path.contains('\0') {
            return Ok(Err("path has a NUL byte".to_owned()));
        }
        match open_without_following(&path) {
            Ok(file) => {
                let fd = descriptor_of(&file);
                with_descriptors(|table| table.insert(fd, file));
                Ok(Ok(fd))
            }
            Err(error) => Ok(Err(message(&error))),
        }
    }
}

/// Opens `path` for reading, refusing a symbolic link in its last part, without blocking.
#[cfg(unix)]
fn open_without_following(path: &str) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    use rustix::fs::OFlags;

    OpenOptions::new()
        .read(true)
        .custom_flags(
            (OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK)
                .bits()
                .cast_signed(),
        )
        .open(path)
}

/// Opens `path` for reading, refusing a symbolic link in its last part.
#[cfg(not(unix))]
fn open_without_following(path: &str) -> io::Result<File> {
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Too many levels of symbolic links",
        ));
    }
    File::open(path)
}

/// Returns the number that names `file` in the descriptor table.
#[must_use]
#[cfg(unix)]
fn descriptor_of(file: &File) -> i32 {
    use std::os::fd::AsRawFd;

    file.as_raw_fd()
}

/// Returns the number that names `file` in the descriptor table, a fresh one off unix.
#[cfg(not(unix))]
fn descriptor_of(_file: &File) -> i32 {
    NEXT_DESCRIPTOR.fetch_add(1, Ordering::Relaxed)
}

native_fn! {
    /// Reads the owner, mode, size and kind of an open descriptor.
    pub fn fstat(_lua: &Lua, fd: i32) -> mlua::Result<Result<FsStat, String>> {
        let meta = with_descriptors(|table| table.get(&fd).map(File::metadata));
        Ok(match meta {
            Some(Ok(meta)) => Ok(stat_of(&meta)),
            Some(Err(error)) => Err(message(&error)),
            None => Err("Bad file descriptor".to_owned()),
        })
    }
}

/// Reads up to `limit` bytes from `file`, retrying when a signal interrupts the read.
fn read_up_to(mut file: &File, limit: usize) -> crate::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut chunk = vec![0_u8; READ_CHUNK_BYTES.min(limit.max(1))];
    while bytes.len() < limit {
        let want = chunk.len().min(limit - bytes.len());
        match file.read(&mut chunk[..want]) {
            Ok(0) => break,
            Ok(count) => bytes.extend_from_slice(&chunk[..count]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(crate::Error::Message(message(&error))),
        }
    }
    Ok(bytes)
}

native_fn! {
    /// Reads up to `limit` bytes from an open descriptor.
    pub fn read_fd(lua: &Lua, fd: i32, limit: usize) -> mlua::Result<Result<LuaString, String>> {
        let outcome = with_descriptors(|table| match table.get(&fd) {
            Some(file) => read_up_to(file, limit).map_err(|error| error.to_string()),
            None => Err("Bad file descriptor".to_owned()),
        });
        match outcome {
            Ok(bytes) => Ok(Ok(lua.create_string(bytes)?)),
            Err(text) => Ok(Err(text)),
        }
    }
}

native_fn! {
    /// Closes a descriptor opened by `open_nofollow`.
    pub fn close(_lua: &Lua, fd: i32) -> mlua::Result<()> {
        with_descriptors(|table| table.remove(&fd));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Makes a fresh folder under the system temp folder.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "dev-fs-test-{tag}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn dirname_should_keep_the_edge_cases() {
        assert_eq!(dir_part("a"), ".");
        assert_eq!(dir_part("/"), "/");
        assert_eq!(dir_part(""), ".");
        assert_eq!(dir_part("/a"), "/");
        assert_eq!(dir_part("a/b/"), "a");
        assert_eq!(dir_part("a//b"), "a");
    }

    #[test]
    fn basename_should_keep_the_edge_cases() {
        assert_eq!(base_part("/"), "/");
        assert_eq!(base_part(""), "");
        assert_eq!(base_part("a/b/"), "b");
        assert_eq!(base_part("a"), "a");
    }

    #[test]
    fn join_should_collapse_repeated_slashes() {
        let parts = ["/a/".to_owned(), "/b".to_owned(), "c".to_owned()];
        assert_eq!(join_parts(&parts), "/a/b/c");
    }

    #[test]
    fn kind_of_should_read_the_type_bits() {
        assert_eq!(kind_of(0o100_644), "file");
        assert_eq!(kind_of(0o040_755), "dir");
        assert_eq!(kind_of(0o120_777), "link");
        assert_eq!(kind_of(0o010_644), "other");
    }

    #[test]
    fn strip_verbatim_should_drop_the_prefix_of_a_drive_path() {
        assert_eq!(
            strip_verbatim(r"\\?\C:\Users\dev").as_deref(),
            Some(r"C:\Users\dev")
        );
    }

    #[test]
    fn strip_verbatim_should_turn_a_verbatim_share_into_a_unc_path() {
        assert_eq!(
            strip_verbatim(r"\\?\UNC\server\share\dir").as_deref(),
            Some(r"\\server\share\dir")
        );
    }

    #[test]
    fn strip_verbatim_should_leave_other_paths_alone() {
        assert_eq!(strip_verbatim(r"C:\Users\dev"), None);
        assert_eq!(strip_verbatim("/usr/bin"), None);
        assert_eq!(strip_verbatim(r"\\?\Volume{1234}\dir"), None);
        assert_eq!(strip_verbatim(r"\\?\"), None);
    }

    #[test]
    fn canonical_should_resolve_an_existing_path_without_a_verbatim_prefix() {
        let dir = scratch("canonical");
        let real = canonical(&dir).unwrap();
        assert!(!real.to_string_lossy().starts_with(r"\\?\"));
        assert!(real.is_absolute());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn message_should_drop_the_os_error_tail() {
        let error = fs::read("/nonexistent/dev-fs-test").unwrap_err();
        assert!(error.to_string().contains("(os error "));
        assert!(!message(&error).contains("os error"));
    }

    #[test]
    fn write_atomic_should_replace_the_file_and_leave_no_temp() {
        let dir = scratch("atomic");
        let target = dir.join("out.txt");
        fs::write(&target, "old").unwrap();
        write_atomic(&target, b"new", None).unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "new");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn write_atomic_should_fail_without_a_parent_folder() {
        let dir = scratch("atomic-fail");
        let target = dir.join("missing").join("out.txt");
        assert!(write_atomic(&target, b"new", None).is_err());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn open_for_write_should_apply_the_mode_to_a_new_file() {
        let dir = scratch("mode");
        let target = dir.join("secret");
        drop(open_for_write(&target, Some(0o600)).unwrap());
        if cfg!(unix) {
            assert_eq!(
                mode::mode_of(&fs::metadata(&target).unwrap()) & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn copy_tree_should_copy_files_links_and_folders() {
        let dir = scratch("copy");
        let from = dir.join("from");
        fs::create_dir_all(from.join("sub")).unwrap();
        fs::write(from.join("sub/file"), "x").unwrap();
        make_symlink(Path::new("sub/file"), &from.join("link")).unwrap();
        let to = dir.join("to");
        copy_tree(&from, &to).unwrap();
        assert_eq!(fs::read_to_string(to.join("sub/file")).unwrap(), "x");
        assert_eq!(
            fs::read_link(to.join("link")).unwrap(),
            Path::new("sub/file")
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn random_suffix_should_have_the_template_length() {
        assert_eq!(random_suffix(1).len(), NAME_SUFFIX_LEN);
    }

    #[test]
    fn read_up_to_should_stop_at_the_limit() {
        let dir = scratch("read");
        let path = dir.join("f");
        fs::write(&path, "abcdef").unwrap();
        let file = File::open(&path).unwrap();
        assert_eq!(read_up_to(&file, 4).unwrap(), b"abcd");
        fs::remove_dir_all(&dir).unwrap();
    }
}

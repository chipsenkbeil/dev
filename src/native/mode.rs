use std::fs::{self, File, Metadata, OpenOptions};
use std::io;
use std::path::Path;

/// File type bits of a synthesized `st_mode`, for a directory.
#[cfg(any(windows, test))]
const DIR_BITS: u32 = 0o040_000;

/// File type bits of a synthesized `st_mode`, for a regular file.
#[cfg(any(windows, test))]
const FILE_BITS: u32 = 0o100_000;

/// File type bits of a synthesized `st_mode`, for a symbolic link.
#[cfg(any(windows, test))]
const LINK_BITS: u32 = 0o120_000;

/// What a path is, for a platform without mode bits.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug)]
enum Kind {
    /// A regular file.
    File,
    /// A folder.
    Dir,
    /// A symbolic link.
    Link,
}

/// Builds the `st_mode` of a platform without mode bits: the type, and write bits unless read-only.
#[must_use]
#[cfg(any(windows, test))]
fn synthesize(kind: Kind, readonly: bool) -> u32 {
    let write = if readonly { 0 } else { 0o200 };
    match kind {
        Kind::Link => LINK_BITS | 0o777,
        Kind::Dir => DIR_BITS | 0o111 | 0o444 | write,
        Kind::File => FILE_BITS | 0o444 | write,
    }
}

/// Asks the creating call to give the new file permission bits `mode`, where the platform has them.
#[cfg(unix)]
pub fn create_with(options: &mut OpenOptions, mode: u32) -> &mut OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;

    options.mode(mode)
}

/// Asks the creating call to give the new file permission bits `mode`, where the platform has them.
#[cfg(not(unix))]
pub fn create_with(options: &mut OpenOptions, _mode: u32) -> &mut OpenOptions {
    options
}

/// Makes the folder `path` with permission bits `mode`, where the platform has them.
///
/// # Errors
///
/// Returns the error of the system call that makes the folder.
#[cfg(unix)]
pub fn create_dir_with(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;

    fs::DirBuilder::new().mode(mode).create(path)
}

/// Makes the folder `path` with permission bits `mode`, where the platform has them.
///
/// # Errors
///
/// Returns the error of the system call that makes the folder.
#[cfg(not(unix))]
pub fn create_dir_with(path: &Path, _mode: u32) -> io::Result<()> {
    fs::create_dir(path)
}

/// Sets the permission bits of an open file.
///
/// # Errors
///
/// Returns the error of the system call that sets them.
#[cfg(unix)]
pub fn set_file_mode(file: &File, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    file.set_permissions(fs::Permissions::from_mode(mode))
}

/// Sets the permission bits of an open file, which only the read-only flag stands for here.
///
/// # Errors
///
/// Returns the error of the system call that sets them.
#[cfg(not(unix))]
pub fn set_file_mode(file: &File, mode: u32) -> io::Result<()> {
    let mut permissions = file.metadata()?.permissions();
    permissions.set_readonly(mode & 0o200 == 0);
    file.set_permissions(permissions)
}

/// Sets the permission bits of `path`.
///
/// # Errors
///
/// Returns the error of the system call that sets them.
#[cfg(unix)]
pub fn set_path_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

/// Sets the permission bits of `path`, which only the read-only flag stands for here.
///
/// # Errors
///
/// Returns the error of the system call that sets them.
#[cfg(not(unix))]
pub fn set_path_mode(path: &Path, mode: u32) -> io::Result<()> {
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_readonly(mode & 0o200 == 0);
    fs::set_permissions(path, permissions)
}

/// Returns the raw `st_mode` of `meta`, synthesized from its type and read-only flag off unix.
#[must_use]
#[cfg(unix)]
pub fn mode_of(meta: &Metadata) -> u32 {
    use std::os::unix::fs::MetadataExt;

    meta.mode()
}

/// Returns the raw `st_mode` of `meta`, synthesized from its type and read-only flag off unix.
#[must_use]
#[cfg(not(unix))]
pub fn mode_of(meta: &Metadata) -> u32 {
    let kind = if meta.file_type().is_symlink() {
        Kind::Link
    } else if meta.is_dir() {
        Kind::Dir
    } else {
        Kind::File
    };
    synthesize(kind, meta.permissions().readonly())
}

/// Returns the owner's user id of `meta`.
#[must_use]
#[cfg(unix)]
pub fn owner_of(meta: &Metadata) -> u32 {
    use std::os::unix::fs::MetadataExt;

    meta.uid()
}

/// Returns the id that stands for a user who is never root, where the platform has no owner ids.
#[must_use]
#[cfg(not(unix))]
pub fn owner_of(_meta: &Metadata) -> u32 {
    u32::MAX
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthesize_should_name_the_type_and_drop_write_for_read_only() {
        assert_eq!(synthesize(Kind::File, false), 0o100_644);
        assert_eq!(synthesize(Kind::File, true), 0o100_444);
        assert_eq!(synthesize(Kind::Dir, false), 0o040_755);
        assert_eq!(synthesize(Kind::Link, false), 0o120_777);
    }
}

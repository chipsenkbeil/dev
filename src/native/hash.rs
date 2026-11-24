use std::fs::File;
use std::io::{self, Read};

use mlua::{Lua, LuaString, Table};
use sha2::{Digest, Sha256};

use crate::native_fn;

/// Name of this module under `dev`.
pub const NAME: &str = "hash";

/// Bytes read from a file per chunk.
const CHUNK_BYTES: usize = 65536;

/// Creates the `dev.hash` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    sha256::register(lua, NAME, &table)?;
    sha256_file::register(lua, NAME, &table)?;
    Ok(table)
}

/// Writes a digest as lowercase hex.
fn hex(digest: &[u8]) -> String {
    let mut text = String::with_capacity(digest.len() * 2);
    for &byte in digest {
        text.push(char::from_digit(u32::from(byte >> 4), 16).unwrap_or(char::from(b'0')));
        text.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap_or(char::from(b'0')));
    }
    text
}
/// Words an I/O failure on `path` as `PATH: MESSAGE`, without Rust's `(os error N)` tail.
fn at(path: &str, error: &io::Error) -> crate::Error {
    let text = error.to_string();
    let text = text
        .rfind(" (os error ")
        .map_or(text.as_str(), |end| &text[..end]);
    crate::Error::Message(format!("{path}: {text}"))
}

/// Streams a reader through SHA-256 and returns the lowercase hex digest.
fn digest_reader(mut reader: impl Read, path: &str) -> crate::Result<String> {
    let mut hasher = Sha256::new();
    let mut chunk = vec![0_u8; CHUNK_BYTES];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => hasher.update(&chunk[..count]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(at(path, &error)),
        }
    }
    Ok(hex(&hasher.finalize()))
}

/// Opens `path` and streams it through SHA-256.
fn digest_file(path: &str) -> crate::Result<String> {
    let file = File::open(path).map_err(|error| at(path, &error))?;
    digest_reader(file, path)
}

native_fn! {
    /// Returns the SHA-256 digest of `text` as lowercase hex.
    pub fn sha256(_lua: &Lua, text: LuaString) -> mlua::Result<String> {
        Ok(hex(&Sha256::digest(&*text.as_bytes())))
    }
}

native_fn! {
    /// Returns the SHA-256 digest of a file as lowercase hex, reading it in chunks.
    pub fn sha256_file(_lua: &Lua, path: String) -> mlua::Result<Result<String, String>> {
        Ok(digest_file(&path).map_err(|error| error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    const EMPTY: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn hex_should_pad_each_byte_to_two_digits() {
        assert_eq!(hex(&[0, 15, 255]), "000fff");
    }

    #[test]
    fn digest_reader_should_match_the_known_vectors() {
        assert_eq!(digest_reader(Cursor::new(b""), "x").unwrap(), EMPTY);
        assert_eq!(digest_reader(Cursor::new(b"abc"), "x").unwrap(), ABC);
    }

    #[test]
    fn digest_reader_should_stream_more_than_one_chunk() {
        let big = vec![b'a'; CHUNK_BYTES * 2 + 7];
        let streamed = digest_reader(Cursor::new(&big), "x").unwrap();
        assert_eq!(streamed, hex(&Sha256::digest(&big)));
    }
}

use std::{fmt, io};

/// Result of dev's own helpers, the code below the Luau boundary.
pub type Result<T> = std::result::Result<T, Error>;

/// A failure inside dev, below the Luau boundary.
///
/// A native function returns an expected failure to Luau as `nil, reason` with `to_string()`,
/// and raises misuse with `?` through `From<Error> for mlua::Error`.
#[derive(Debug)]
pub enum Error {
    /// A failed file, folder, process or stream operation, with what dev was doing.
    Io {
        /// What dev was doing, worded to follow "failed to", such as "read /etc/x".
        action: String,
        /// The error the operating system gave.
        source: io::Error,
    },
    /// Text that does not parse, with what it was and why.
    Parse {
        /// What was being parsed, such as a path or "the response".
        what: String,
        /// Why it does not parse.
        reason: String,
    },
    /// Any other failure, as a lowercase phrase.
    Message(String),
}

impl Error {
    /// Returns an [`Error::Io`] for `action`, worded to follow "failed to".
    #[must_use]
    pub fn io(action: impl Into<String>, source: io::Error) -> Self {
        Self::Io {
            action: action.into(),
            source,
        }
    }

    /// Returns an [`Error::Parse`] of `what` for `reason`.
    #[must_use]
    pub fn parse(what: impl Into<String>, reason: impl Into<String>) -> Self {
        Self::Parse {
            what: what.into(),
            reason: reason.into(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { action, source } => write!(f, "failed to {action}: {source}"),
            Self::Parse { what, reason } => write!(f, "invalid {what}: {reason}"),
            Self::Message(text) => f.write_str(text),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Parse { .. } | Self::Message(_) => None,
        }
    }
}

impl From<Error> for mlua::Error {
    fn from(error: Error) -> Self {
        Self::external(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_should_word_each_failure_as_a_phrase() {
        let missing = io::Error::new(io::ErrorKind::NotFound, "no such file");
        assert_eq!(
            Error::io("read /x", missing).to_string(),
            "failed to read /x: no such file"
        );
        assert_eq!(
            Error::parse("dev.toml", "line 3: expected `=`").to_string(),
            "invalid dev.toml: line 3: expected `=`"
        );
        assert_eq!(
            Error::Message("no board".to_owned()).to_string(),
            "no board"
        );
    }

    #[test]
    fn into_mlua_should_keep_the_phrase() {
        let error = mlua::Error::from(Error::Message("it broke".to_owned()));
        assert_eq!(error.to_string(), "it broke");
    }
}

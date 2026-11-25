//! A fake HTTP server for the Lua suites.
//!
//! `fake_http ROUTES [--log FILE]` binds a free port on 127.0.0.1, prints the port on one line,
//! and serves one connection at a time until it is killed. ROUTES is read again on every request,
//! so a suite can rewrite it between calls. A line holds up to seven tab-separated fields and the
//! first line that matches wins.
//!
//! 1. method, or `*` for any
//! 2. a pattern for the path without its query, or for the whole target when it holds a `?`;
//!    `*` stands for any run of bytes and `#` for one lowercase hex digit or dash
//! 3. status, 0 to close the connection without an answer, or -1 to stop listening and then
//!    reset the connection, so every later connect is refused
//! 4. headers as `Name: value` joined by `|`, or `-`
//! 5. body file, relative to ROUTES, or `-` for an empty body
//! 6. a text the request target, headers or body must contain, or `-` for no condition (optional)
//! 7. `SRC>DEST` to copy the file SRC over DEST when the route answers, or `-` (optional)
//!
//! A request that no line matches gets a 404. With `--log`, each request appends a line
//! `METHOD PATH?QUERY body=BODY` with newlines in BODY written as `\n`, then one `  Name: value`
//! line per request header, with each word of the name capitalised.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

/// One request as the server read it.
struct Request {
    /// The request method.
    method: String,
    /// The request target, with its query.
    target: String,
    /// The header lines.
    headers: Vec<String>,
    /// The body, lossily decoded.
    body: String,
}

/// One answer picked from the routes file.
struct Answer {
    /// The status code.
    status: i32,
    /// The headers to send.
    headers: Vec<String>,
    /// The body bytes.
    body: Vec<u8>,
}

fn read_request(stream: &TcpStream) -> Option<Request> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut words = line.split_whitespace();
    let method = words.next()?.to_owned();
    let target = words.next()?.to_owned();
    let mut headers = Vec::new();
    let mut length = 0_usize;
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).ok()?;
        let header = header.trim_end().to_owned();
        if header.is_empty() {
            break;
        }
        if let Some(value) = header.to_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse().ok()?;
        }
        headers.push(header);
    }
    let mut body = vec![0_u8; length];
    reader.read_exact(&mut body).ok()?;
    Some(Request {
        method,
        target,
        headers,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

/// Matches `text` against `pattern`, where `*` stands for any run of bytes and `#` for one byte of
/// a lowercase hex digit or a dash.
fn glob(pattern: &[u8], text: &[u8]) -> bool {
    let (mut p, mut t) = (0, 0);
    let mut resume: Option<(usize, usize)> = None;
    while t < text.len() {
        match pattern.get(p) {
            Some(b'*') => {
                resume = Some((p, t));
                p += 1;
            }
            Some(b'#') if text[t].is_ascii_digit() || matches!(text[t], b'a'..=b'f' | b'-') => {
                p += 1;
                t += 1;
            }
            Some(&byte) if byte != b'#' && byte == text[t] => {
                p += 1;
                t += 1;
            }
            _ => match resume {
                Some((star, at)) => {
                    resume = Some((star, at + 1));
                    p = star + 1;
                    t = at + 1;
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|&byte| byte == b'*')
}

/// Answers 500 with the reason a matched route could not be served.
fn failure(reason: String) -> Option<Answer> {
    Some(Answer {
        status: 500,
        headers: Vec::new(),
        body: reason.into_bytes(),
    })
}

fn route(routes: &Path, request: &Request) -> Option<Answer> {
    let text = fs::read_to_string(routes).ok()?;
    let path = request.target.split('?').next().unwrap_or("");
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 5 {
            continue;
        }
        let method_ok = fields[0] == "*" || fields[0] == request.method;
        let subject = if fields[1].contains('?') {
            request.target.as_str()
        } else {
            path
        };
        let path_ok = glob(fields[1].as_bytes(), subject.as_bytes());
        let needle = fields.get(5).copied().unwrap_or("-");
        let body_ok = needle == "-"
            || request.body.contains(needle)
            || request.target.contains(needle)
            || request.headers.iter().any(|header| header.contains(needle));
        if !(method_ok && path_ok && body_ok) {
            continue;
        }
        let headers = match fields[3] {
            "-" => Vec::new(),
            joined => joined.split('|').map(str::to_owned).collect(),
        };
        let body = match fields[4] {
            "-" => Vec::new(),
            name => match fs::read(routes.parent().unwrap_or(Path::new(".")).join(name)) {
                Ok(bytes) => bytes,
                Err(error) => return failure(format!("body file {name}: {error}")),
            },
        };
        let Ok(status) = fields[2].parse() else {
            return failure(format!("bad status {}", fields[2]));
        };
        if let Some((from, to)) = fields.get(6).and_then(|copy| copy.split_once('>')) {
            let staged = format!("{to}.tmp");
            if fs::copy(from, &staged).is_ok() {
                let _ = fs::rename(&staged, to);
            }
        }
        return Some(Answer {
            status,
            headers,
            body,
        });
    }
    None
}

/// Writes the name of a header line with a capital after each dash, as `If-Owner-Fence`.
fn canonical(header: &str) -> String {
    let Some((name, value)) = header.split_once(':') else {
        return header.to_owned();
    };
    let name: Vec<String> = name
        .split('-')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first
                    .to_uppercase()
                    .chain(chars.flat_map(char::to_lowercase))
                    .collect(),
                None => String::new(),
            }
        })
        .collect();
    format!("{}:{value}", name.join("-"))
}

fn record(log: &Path, request: &Request) {
    let mut text = format!(
        "{} {} body={}\n",
        request.method,
        request.target,
        request.body.replace('\n', "\\n")
    );
    for header in &request.headers {
        text.push_str(&format!("  {}\n", canonical(header)));
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(log) {
        let _ = file.write_all(text.as_bytes());
    }
}

/// Answers one connection, or hands it back unanswered when its route says to stop.
fn serve(mut stream: TcpStream, routes: &Path, log: Option<&Path>) -> Option<TcpStream> {
    let request = read_request(&stream)?;
    if let Some(log) = log {
        record(log, &request);
    }
    let answer = route(routes, &request).unwrap_or_else(|| Answer {
        status: 404,
        headers: Vec::new(),
        body: b"no route".to_vec(),
    });
    if answer.status < 0 {
        return Some(stream);
    }
    if answer.status == 0 {
        return None;
    }
    let mut head = format!(
        "HTTP/1.1 {} X\r\nContent-Length: {}\r\nConnection: close\r\n",
        answer.status,
        answer.body.len()
    );
    for header in &answer.headers {
        head.push_str(header);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(&answer.body);
    None
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(routes) = args.next().map(PathBuf::from) else {
        eprintln!("usage: fake_http ROUTES [--log FILE]");
        return ExitCode::from(2);
    };
    let log = match (args.next().as_deref(), args.next()) {
        (Some("--log"), Some(file)) => Some(PathBuf::from(file)),
        _ => None,
    };
    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("fake_http: {error}");
            return ExitCode::FAILURE;
        }
    };
    if let Ok(address) = listener.local_addr() {
        println!("{}", address.port());
        let _ = std::io::stdout().flush();
    }
    loop {
        let Ok((stream, _)) = listener.accept() else {
            continue;
        };
        if let Some(stream) = serve(stream, &routes, log.as_deref()) {
            drop(listener);
            #[cfg(unix)]
            let _ = rustix::net::sockopt::set_socket_linger(&stream, Some(Duration::ZERO));
            drop(stream);
            return ExitCode::SUCCESS;
        }
    }
}

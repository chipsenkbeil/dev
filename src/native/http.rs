use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Cursor, Read, Write};
use std::path::Path;
use std::time::Duration;

use mlua::{Function, IntoLuaMulti, Lua, LuaString, MultiValue, Nil, Table};
use ureq::http::{Request, Uri};
use ureq::tls::{RootCerts, TlsConfig};
use ureq::{Agent, SendBody};

use crate::{native_fn, native_struct};

/// Name of this module under `dev`.
pub const NAME: &str = "http";

/// Bytes moved per read while streaming a body.
const CHUNK_BYTES: usize = 65536;

/// Known places of a CA bundle, for hosts without a platform certificate store.
const CA_FILES: &[&str] = &[
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/ssl/cert.pem",
    "/etc/pki/tls/cert.pem",
];

native_struct! {
    /// Arguments of `request`.
    pub struct RequestOptions {
        /// HTTP method, `GET` by default.
        pub method: Option<String>,
        /// Absolute URL.
        pub url: String,
        /// Request headers by name.
        pub headers: Option<HashMap<String, String>>,
        /// Request body.
        pub body: Option<LuaString>,
        /// File sent as the multipart form field `file`.
        pub file: Option<String>,
        /// Seconds the whole request may take.
        pub timeout: Option<f64>,
        /// Seconds the connection may take to set up.
        pub connect_timeout: Option<f64>,
    }
}

native_struct! {
    /// Arguments of `download`.
    pub struct DownloadOptions {
        /// Absolute URL.
        pub url: String,
        /// File the body is streamed to.
        pub path: String,
        /// Request headers by name.
        pub headers: Option<HashMap<String, String>>,
        /// Seconds the whole download may take.
        pub timeout: Option<f64>,
        /// Seconds the connection may take to set up.
        pub connect_timeout: Option<f64>,
        /// Called with the bytes done and the total when known.
        pub progress: Option<Function>,
    }
}

/// A transport failure, with the kind callers map back to curl's exit codes.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Failure {
    /// Sentence naming the host.
    reason: String,
    /// One of `resolve`, `connect`, `timeout`, `tls` or `other`.
    kind: &'static str,
}

/// What came back from a request, before it reaches Luau.
#[derive(Debug)]
struct Reply {
    /// HTTP status code.
    status: u16,
    /// Response headers, names lowercased and repeated names joined with a comma.
    headers: Vec<(String, String)>,
    /// Body bytes, empty for a download.
    body: Vec<u8>,
}

/// Creates the `dev.http` module table.
///
/// # Errors
///
/// Returns the Lua error when the table cannot be created.
pub fn register(lua: &Lua) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    request::register(lua, NAME, &table)?;
    download::register(lua, NAME, &table)?;
    Ok(table)
}

/// Returns whether the host has a CA bundle the platform verifier can read.
fn has_ca_bundle() -> bool {
    let named = |name: &str| std::env::var_os(name).is_some_and(|path| Path::new(&path).exists());
    named("SSL_CERT_FILE")
        || named("SSL_CERT_DIR")
        || CA_FILES.iter().any(|path| Path::new(path).exists())
}

/// Picks the platform verifier, or the bundled Mozilla roots when the platform has no store.
fn root_certs() -> RootCerts {
    if cfg!(target_os = "macos") || has_ca_bundle() {
        RootCerts::PlatformVerifier
    } else {
        RootCerts::WebPki
    }
}

/// Builds an agent that returns non-2xx statuses as normal replies.
fn agent(timeout: Option<f64>, connect_timeout: Option<f64>) -> Agent {
    let config = Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .user_agent(format!("dev/{}", env!("CARGO_PKG_VERSION")))
        .timeout_global(seconds(timeout))
        .timeout_connect(seconds(connect_timeout))
        .tls_config(TlsConfig::builder().root_certs(root_certs()).build())
        .build();
    Agent::new_with_config(config)
}

/// Turns seconds into a duration, ignoring a missing or invalid value.
fn seconds(value: Option<f64>) -> Option<Duration> {
    value
        .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
        .map(Duration::from_secs_f64)
}

/// Returns the host of `url`, or the whole text when it does not parse.
fn host_of(url: &str) -> String {
    url.parse::<Uri>()
        .ok()
        .and_then(|uri| uri.host().map(str::to_owned))
        .unwrap_or_else(|| url.to_owned())
}

/// Sorts a transport error into one of the failure kinds.
fn kind_of(error: &ureq::Error) -> &'static str {
    match error {
        ureq::Error::HostNotFound => "resolve",
        ureq::Error::ConnectionFailed => "connect",
        ureq::Error::Timeout(_) => "timeout",
        ureq::Error::Tls(_) | ureq::Error::Pem(_) | ureq::Error::Rustls(_) => "tls",
        ureq::Error::Io(error) => match error.kind() {
            io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::HostUnreachable
            | io::ErrorKind::NetworkUnreachable
            | io::ErrorKind::AddrNotAvailable
            | io::ErrorKind::NotConnected => "connect",
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => "timeout",
            _ => "other",
        },
        _ => "other",
    }
}

/// Words a transport error with the host it concerns.
fn failure(url: &str, error: &ureq::Error) -> Failure {
    Failure {
        reason: format!("{}: {error}", host_of(url)),
        kind: kind_of(error),
    }
}

/// Words a failure that is not a transport error.
fn other_failure(url: &str, error: impl std::fmt::Display) -> Failure {
    Failure {
        reason: format!("{}: {error}", host_of(url)),
        kind: "other",
    }
}

/// Collects the response headers, lowercasing names and joining repeats.
fn collect_headers(headers: &ureq::http::HeaderMap) -> Vec<(String, String)> {
    let mut seen: Vec<(String, String)> = Vec::new();
    for (name, value) in headers {
        let text = String::from_utf8_lossy(value.as_bytes()).into_owned();
        let key = name.as_str().to_owned();
        match seen.iter_mut().find(|(known, _)| *known == key) {
            Some((_, joined)) => {
                joined.push_str(", ");
                joined.push_str(&text);
            }
            None => seen.push((key, text)),
        }
    }
    seen
}

/// Returns a boundary that a form body is unlikely to contain.
fn boundary() -> String {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    format!("----------------dev{:x}{stamp:x}", std::process::id())
}

/// Escapes a file name for a form header.
fn quoted(name: &str) -> String {
    name.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Returns the multipart text before and after the file bytes, as curl `-F file=@PATH` sends it.
fn form_frame(boundary: &str, file_name: &str) -> (Vec<u8>, Vec<u8>) {
    let head = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        quoted(file_name)
    );
    let tail = format!("\r\n--{boundary}--\r\n");
    (head.into_bytes(), tail.into_bytes())
}

/// The body of one request.
#[derive(Clone, Debug)]
enum Payload {
    /// No body.
    Empty,
    /// Bytes held in memory.
    Bytes(Vec<u8>),
    /// A file sent as the form field `file`.
    Form(String),
}

/// Everything `send` needs for one request.
struct Call<'a> {
    /// HTTP method.
    method: &'a str,
    /// Absolute URL.
    url: &'a str,
    /// Request headers.
    headers: &'a [(String, String)],
    /// Request body.
    payload: Payload,
    /// Seconds for the whole call.
    timeout: Option<f64>,
    /// Seconds to connect.
    connect_timeout: Option<f64>,
}

/// Sends one request without following a redirect, and returns the response with its body.
fn send_once(call: Call<'_>) -> Result<ureq::http::Response<ureq::Body>, Failure> {
    let url = call.url;
    let mut builder = Request::builder().method(call.method).uri(url);
    for (name, value) in call.headers {
        builder = builder.header(name, value);
    }
    let agent = agent(call.timeout, call.connect_timeout);
    let outcome = match call.payload {
        Payload::Empty => {
            let request = builder
                .body(())
                .map_err(|error| other_failure(url, error))?;
            agent.run(request)
        }
        Payload::Bytes(bytes) => {
            let request = builder
                .body(bytes)
                .map_err(|error| other_failure(url, error))?;
            agent.run(request)
        }
        Payload::Form(path) => {
            let file = File::open(&path)
                .map_err(|error| other_failure(url, format!("{path}: {error}")))?;
            let length = file
                .metadata()
                .map_err(|error| other_failure(url, format!("{path}: {error}")))?
                .len();
            let name = Path::new(&path)
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
            let edge = boundary();
            let (head, tail) = form_frame(&edge, &name);
            let total = head.len() as u64 + length + tail.len() as u64;
            let body = Cursor::new(head).chain(file).chain(Cursor::new(tail));
            let request = builder
                .header(
                    "content-type",
                    format!("multipart/form-data; boundary={edge}"),
                )
                .header("content-length", total)
                .body(SendBody::from_owned_reader(body))
                .map_err(|error| other_failure(url, error))?;
            agent.run(request)
        }
    };
    outcome.map_err(|error| failure(url, &error))
}

/// Most redirects one call follows.
const MAX_REDIRECTS: usize = 10;

/// Returns the host of `uri` without the brackets of an IPv6 literal.
fn bare_host(uri: &Uri) -> String {
    uri.host()
        .map(|host| host.trim_matches(['[', ']']).to_owned())
        .unwrap_or_default()
}

/// Returns whether `host` names this machine.
fn is_loopback(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

/// Resolves a `Location` value against the URL that answered with it.
fn resolve_location(base: &Uri, location: &str) -> Option<Uri> {
    let scheme = base.scheme_str()?;
    let authority = base.authority()?;
    let text = if location.contains("://") {
        location.to_owned()
    } else if let Some(rest) = location.strip_prefix("//") {
        format!("{scheme}://{rest}")
    } else if location.starts_with('/') {
        format!("{scheme}://{authority}{location}")
    } else {
        let path = base.path();
        let dir = path.rfind('/').map_or("/", |end| &path[..=end]);
        format!("{scheme}://{authority}{dir}{location}")
    };
    text.parse().ok()
}

/// Checks that a redirect from `from` to `to` keeps the connection as safe as it was.
///
/// A redirect may not leave http and https, drop from https to http, or send a loopback http
/// URL to another machine over http.
fn check_redirect(from: &Uri, to: &Uri) -> Result<(), String> {
    let target = to.scheme_str().unwrap_or_default();
    if target != "http" && target != "https" {
        return Err(format!("redirect to {to} is not http or https"));
    }
    if target == "https" {
        return Ok(());
    }
    if from.scheme_str() == Some("https") {
        return Err(format!("refused a redirect from https to http at {to}"));
    }
    if is_loopback(&bare_host(from)) && !is_loopback(&bare_host(to)) {
        return Err(format!(
            "refused a redirect from a loopback http URL to {to}"
        ));
    }
    Ok(())
}

/// Sends a request and follows up to ten redirects the policy of [`check_redirect`] allows.
fn send(call: Call<'_>) -> Result<ureq::http::Response<ureq::Body>, Failure> {
    let started = std::time::Instant::now();
    let mut url = call.url.to_owned();
    let mut method = call.method.to_owned();
    let mut payload = call.payload;
    let mut headers = call.headers.to_vec();
    for hop in 0..=MAX_REDIRECTS {
        let left = call
            .timeout
            .map(|total| total - started.elapsed().as_secs_f64());
        if left.is_some_and(|left| left <= 0.0) {
            return Err(Failure {
                reason: format!("{}: the request timed out", host_of(&url)),
                kind: "timeout",
            });
        }
        let response = send_once(Call {
            method: &method,
            url: &url,
            headers: &headers,
            payload: payload.clone(),
            timeout: left,
            connect_timeout: call.connect_timeout,
        })?;
        let status = response.status().as_u16();
        let location = response
            .headers()
            .get("location")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let Some(location) = location.filter(|_| matches!(status, 301 | 302 | 303 | 307 | 308))
        else {
            return Ok(response);
        };
        if hop == MAX_REDIRECTS {
            return Err(other_failure(
                &url,
                format!("followed more than {MAX_REDIRECTS} redirects"),
            ));
        }
        let from: Uri = url
            .parse()
            .map_err(|error| other_failure(&url, format!("{error}")))?;
        let to = resolve_location(&from, &location)
            .ok_or_else(|| other_failure(&url, format!("bad redirect location {location}")))?;
        check_redirect(&from, &to).map_err(|reason| other_failure(&url, reason))?;
        if bare_host(&from) != bare_host(&to) {
            headers.retain(|(name, _)| !name.eq_ignore_ascii_case("authorization"));
        }
        let drop_body =
            status == 303 || (matches!(status, 301 | 302) && method != "GET" && method != "HEAD");
        if drop_body {
            method = "GET".to_owned();
            payload = Payload::Empty;
            headers.retain(|(name, _)| {
                !name.eq_ignore_ascii_case("content-type")
                    && !name.eq_ignore_ascii_case("content-length")
            });
        }
        url = to.to_string();
    }
    Err(other_failure(&url, "redirect loop"))
}

/// Runs a request and reads the whole response body.
fn perform(call: Call<'_>) -> Result<Reply, Failure> {
    let url = call.url.to_owned();
    let mut response = send(call)?;
    let status = response.status().as_u16();
    let headers = collect_headers(response.headers());
    let body = response
        .body_mut()
        .with_config()
        .limit(u64::MAX)
        .read_to_vec()
        .map_err(|error| failure(&url, &error))?;
    Ok(Reply {
        status,
        headers,
        body,
    })
}

/// Why a download stopped before it finished.
#[derive(Debug, PartialEq, Eq)]
enum Stop {
    /// The transfer failed.
    Failed(Failure),
    /// The progress callback asked to stop.
    Aborted,
}

impl From<Failure> for Stop {
    fn from(failed: Failure) -> Self {
        Self::Failed(failed)
    }
}

/// Streams the body of `url` to `path` on a 2xx status, calling `progress(done, total)`.
///
/// `progress` returns `false` to stop the transfer, which removes the partial file.
fn fetch(
    call: Call<'_>,
    path: &str,
    progress: impl FnMut(u64, Option<u64>) -> bool,
) -> Result<Reply, Stop> {
    let url = call.url.to_owned();
    let mut response = send(call)?;
    let status = response.status().as_u16();
    let headers = collect_headers(response.headers());
    let reply = Reply {
        status,
        headers,
        body: Vec::new(),
    };
    if !(200..300).contains(&status) {
        return Ok(reply);
    }
    let total = response.body().content_length();
    let mut reader = response.body_mut().with_config().limit(u64::MAX).reader();
    stream_to_file(&mut reader, total, &url, path, progress)?;
    Ok(reply)
}

/// Copies the local file behind a `file://` URL to `path` as a 200 reply, calling
/// `progress(done, total)`. A file that cannot be opened fails with kind `other`.
fn fetch_local(
    url: &str,
    path: &str,
    progress: impl FnMut(u64, Option<u64>) -> bool,
) -> Result<Reply, Stop> {
    let source = url.strip_prefix("file://").unwrap_or(url);
    if !source.starts_with('/') {
        return Err(other_failure(url, "a file:// URL needs an absolute path").into());
    }
    let mut file =
        File::open(source).map_err(|error| other_failure(url, format!("{source}: {error}")))?;
    let total = file.metadata().ok().map(|meta| meta.len());
    stream_to_file(&mut file, total, url, path, progress)?;
    Ok(Reply {
        status: 200,
        headers: Vec::new(),
        body: Vec::new(),
    })
}

/// Writes everything `reader` yields to `path`, calling `progress(done, total)` per chunk.
///
/// A failure or a `false` from `progress` removes the partial file.
fn stream_to_file(
    reader: &mut impl Read,
    total: Option<u64>,
    url: &str,
    path: &str,
    mut progress: impl FnMut(u64, Option<u64>) -> bool,
) -> Result<(), Stop> {
    let mut file =
        File::create(path).map_err(|error| other_failure(url, format!("{path}: {error}")))?;
    let mut chunk = vec![0_u8; CHUNK_BYTES];
    let mut done = 0_u64;
    let streamed: Result<(), Failure> = loop {
        match reader.read(&mut chunk) {
            Ok(0) => break Ok(()),
            Ok(count) => {
                if let Err(error) = file.write_all(&chunk[..count]) {
                    break Err(other_failure(url, format!("{path}: {error}")));
                }
                done += count as u64;
                if !progress(done, total) {
                    drop(file);
                    drop(std::fs::remove_file(path));
                    return Err(Stop::Aborted);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                let kind = if error.kind() == io::ErrorKind::TimedOut {
                    "timeout"
                } else {
                    "other"
                };
                break Err(Failure {
                    reason: format!("{}: {error}", host_of(url)),
                    kind,
                });
            }
        }
    };
    if let Err(failed) = streamed {
        drop(file);
        drop(std::fs::remove_file(path));
        return Err(Stop::Failed(failed));
    }
    Ok(())
}

/// Builds the `{status, headers}` table, and `body` when given.
fn reply_table(lua: &Lua, reply: Reply, with_body: bool) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("status", reply.status)?;
    let headers = lua.create_table()?;
    for (name, value) in reply.headers {
        headers.set(name, value)?;
    }
    table.set("headers", headers)?;
    if with_body {
        table.set("body", lua.create_string(reply.body)?)?;
    }
    Ok(table)
}

/// Turns a failure into the Luau triple `nil, reason, kind`.
fn failure_values(lua: &Lua, failed: &Failure) -> mlua::Result<MultiValue> {
    (Nil, failed.reason.as_str(), failed.kind).into_lua_multi(lua)
}

/// Turns header options into a list of pairs.
fn header_pairs(headers: Option<HashMap<String, String>>) -> Vec<(String, String)> {
    let mut pairs: Vec<(String, String)> = headers.unwrap_or_default().into_iter().collect();
    pairs.sort();
    pairs
}

native_fn! {
    /// Sends one HTTP request. A non-2xx status is a normal result, and a transport failure
    /// returns nil, a reason naming the host and a kind: resolve, connect, timeout, tls or other.
    #[luau = "(opts: { method: string?, url: string, headers: { [string]: string }?, body: string?, file: string?, timeout: number?, connect_timeout: number? }) -> ({ status: number, headers: { [string]: string }, body: string }?, string?, ...any)"]
    pub fn request(lua: &Lua, opts: RequestOptions) -> mlua::Result<MultiValue> {
        if opts.body.is_some() && opts.file.is_some() {
            return Err(mlua::Error::runtime(
                "bad argument #1 to 'request' (body and file cannot both be given)",
            ));
        }
        let payload = match (opts.file, opts.body) {
            (Some(path), _) => Payload::Form(path),
            (None, Some(body)) => Payload::Bytes(body.as_bytes().to_vec()),
            (None, None) => Payload::Empty,
        };
        let headers = header_pairs(opts.headers);
        let method = opts.method.unwrap_or_else(|| "GET".to_owned());
        let call = Call {
            method: &method,
            url: &opts.url,
            headers: &headers,
            payload,
            timeout: opts.timeout,
            connect_timeout: opts.connect_timeout,
        };
        match perform(call) {
            Ok(reply) => reply_table(lua, reply, true)?.into_lua_multi(lua),
            Err(failed) => failure_values(lua, &failed),
        }
    }
}

native_fn! {
    /// Streams a URL to a file, following redirects, and returns the status and headers. A
    /// `file://` URL copies the local file as status 200. The file is written only for a 2xx
    /// status. `progress(done, total?)` is called as it goes.
    #[luau = "(opts: { url: string, path: string, headers: { [string]: string }?, timeout: number?, connect_timeout: number?, progress: ((number, number?) -> ())? }) -> ({ status: number, headers: { [string]: string } }?, string?, ...any)"]
    pub fn download(lua: &Lua, opts: DownloadOptions) -> mlua::Result<MultiValue> {
        let headers = header_pairs(opts.headers);
        let call = Call {
            method: "GET",
            url: &opts.url,
            headers: &headers,
            payload: Payload::Empty,
            timeout: opts.timeout,
            connect_timeout: opts.connect_timeout,
        };
        let progress = opts.progress;
        let mut raised = None;
        let report = |done, total| {
            let Some(function) = &progress else {
                return true;
            };
            match function.call::<()>((done, total)) {
                Ok(()) => true,
                Err(error) => {
                    raised = Some(error);
                    false
                }
            }
        };
        let outcome = if opts.url.starts_with("file://") {
            fetch_local(&opts.url, &opts.path, report)
        } else {
            fetch(call, &opts.path, report)
        };
        match outcome {
            Ok(reply) => reply_table(lua, reply, false)?.into_lua_multi(lua),
            Err(Stop::Aborted) => Err(raised.unwrap_or_else(|| mlua::Error::runtime("download stopped"))),
            Err(Stop::Failed(failed)) => failure_values(lua, &failed),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;
    use std::thread::{self, JoinHandle};

    use super::*;

    /// One request a test server read: its head lines and body bytes.
    struct Seen {
        /// Request line and headers, one per line.
        head: Vec<String>,
        /// Body bytes.
        body: Vec<u8>,
    }

    /// Serves one canned response on a free local port and returns what it received.
    fn serve_once(response: Vec<u8>) -> (String, JoinHandle<Seen>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/path", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = Vec::new();
            let mut length = 0_usize;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let line = line.trim_end().to_owned();
                if line.is_empty() {
                    break;
                }
                if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap();
                }
                head.push(line);
            }
            let mut body = vec![0_u8; length];
            reader.read_exact(&mut body).unwrap();
            let mut stream = stream;
            stream.write_all(&response).unwrap();
            Seen { head, body }
        });
        (url, handle)
    }

    /// Builds a canned response.
    fn reply(status: &str, extra: &str, body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    /// Makes a call with no body or headers.
    fn plain<'a>(method: &'a str, url: &'a str) -> Call<'a> {
        Call {
            method,
            url,
            headers: &[],
            payload: Payload::Empty,
            timeout: Some(10.0),
            connect_timeout: Some(5.0),
        }
    }

    #[test]
    fn perform_should_return_status_headers_and_body() {
        let (url, server) = serve_once(reply("200 OK", "Retry-After: 7\r\n", "hello"));
        let got = perform(plain("GET", &url)).unwrap();
        assert_eq!(got.status, 200);
        assert_eq!(got.body, b"hello");
        assert!(
            got.headers
                .contains(&("retry-after".to_owned(), "7".to_owned()))
        );
        let seen = server.join().unwrap();
        assert!(seen.head[0].starts_with("GET /path"));
    }

    #[test]
    fn perform_should_treat_a_non_2xx_status_as_a_normal_reply() {
        let (url, server) = serve_once(reply("429 Too Many Requests", "", "slow down"));
        let got = perform(plain("GET", &url)).unwrap();
        assert_eq!(got.status, 429);
        assert_eq!(got.body, b"slow down");
        server.join().unwrap();
    }

    #[test]
    fn perform_should_send_a_json_body_and_headers() {
        let (url, server) = serve_once(reply("201 Created", "", "{}"));
        let headers = [("Content-Type".to_owned(), "application/json".to_owned())];
        let mut call = plain("POST", &url);
        call.headers = &headers;
        call.payload = Payload::Bytes(b"{\"a\":1}".to_vec());
        assert_eq!(perform(call).unwrap().status, 201);
        let seen = server.join().unwrap();
        assert_eq!(seen.body, b"{\"a\":1}");
        assert!(
            seen.head
                .iter()
                .any(|line| line.eq_ignore_ascii_case("content-type: application/json"))
        );
    }

    #[test]
    fn perform_should_upload_a_file_as_the_form_field_file() {
        let dir = std::env::temp_dir().join(format!("dev-http-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("note.txt");
        std::fs::write(&path, "file bytes").unwrap();
        let (url, server) = serve_once(reply("200 OK", "", "ok"));
        let mut call = plain("POST", &url);
        call.payload = Payload::Form(path.to_string_lossy().into_owned());
        assert_eq!(perform(call).unwrap().status, 200);
        let seen = server.join().unwrap();
        let text = String::from_utf8(seen.body).unwrap();
        assert!(text.contains("name=\"file\"; filename=\"note.txt\""));
        assert!(text.contains("file bytes"));
        assert!(seen.head.iter().any(|line| {
            line.to_lowercase()
                .starts_with("content-type: multipart/form-data; boundary=")
        }));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn perform_should_report_a_refused_connection_as_connect() {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let url = format!("http://127.0.0.1:{port}/");
        let failed = perform(plain("GET", &url)).unwrap_err();
        assert_eq!(failed.kind, "connect");
        assert!(failed.reason.starts_with("127.0.0.1:"));
    }

    #[test]
    fn perform_should_report_a_silent_server_as_timeout() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let mut call = plain("GET", &url);
        call.timeout = Some(0.3);
        let failed = perform(call).unwrap_err();
        assert_eq!(failed.kind, "timeout");
        drop(listener);
    }

    #[test]
    fn fetch_should_stream_a_2xx_body_to_the_file_with_progress() {
        let dir = std::env::temp_dir().join(format!("dev-http-dl-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.bin");
        let (url, server) = serve_once(reply("200 OK", "", "payload"));
        let mut calls = Vec::new();
        let got = fetch(plain("GET", &url), path.to_str().unwrap(), |done, total| {
            calls.push((done, total));
            true
        });
        assert_eq!(got.unwrap().status, 200);
        assert_eq!(std::fs::read(&path).unwrap(), b"payload");
        assert_eq!(calls.last(), Some(&(7, Some(7))));
        server.join().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn fetch_should_not_create_the_file_for_a_non_2xx_status() {
        let dir = std::env::temp_dir().join(format!("dev-http-404-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.bin");
        let (url, server) = serve_once(reply("404 Not Found", "", "nope"));
        let got = fetch(plain("GET", &url), path.to_str().unwrap(), |_, _| true);
        assert_eq!(got.unwrap().status, 404);
        assert!(!path.exists());
        server.join().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn fetch_local_should_copy_the_file_as_a_200_with_progress() {
        let dir = std::env::temp_dir().join(format!("dev-http-local-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("in.bin");
        let path = dir.join("out.bin");
        std::fs::write(&source, b"payload").unwrap();
        let url = format!("file://{}", source.display());
        let mut calls = Vec::new();
        let got = fetch_local(&url, path.to_str().unwrap(), |done, total| {
            calls.push((done, total));
            true
        });
        assert_eq!(got.unwrap().status, 200);
        assert_eq!(std::fs::read(&path).unwrap(), b"payload");
        assert_eq!(calls.last(), Some(&(7, Some(7))));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn fetch_local_should_fail_for_a_missing_file_or_a_relative_path() {
        let dir = std::env::temp_dir().join(format!("dev-http-local-miss-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.bin");
        let missing = format!("file://{}/none", dir.display());
        let got = fetch_local(&missing, path.to_str().unwrap(), |_, _| true);
        assert!(matches!(got, Err(Stop::Failed(failed)) if failed.kind == "other"));
        let relative = fetch_local("file://rel/x", path.to_str().unwrap(), |_, _| true);
        assert!(matches!(relative, Err(Stop::Failed(_))));
        assert!(!path.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn form_frame_should_match_curl_field_syntax() {
        let (head, tail) = form_frame("B", "a\"b.txt");
        let head = String::from_utf8(head).unwrap();
        assert!(head.starts_with(
            "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a\\\"b.txt\""
        ));
        assert_eq!(tail, b"\r\n--B--\r\n");
    }

    #[test]
    fn kind_of_should_sort_the_error_variants() {
        assert_eq!(kind_of(&ureq::Error::HostNotFound), "resolve");
        assert_eq!(kind_of(&ureq::Error::ConnectionFailed), "connect");
        assert_eq!(
            kind_of(&ureq::Error::Timeout(ureq::Timeout::Global)),
            "timeout"
        );
        assert_eq!(kind_of(&ureq::Error::Tls("x")), "tls");
        assert_eq!(kind_of(&ureq::Error::TooManyRedirects), "other");
    }

    #[test]
    fn host_of_should_name_the_host_only() {
        assert_eq!(
            host_of("https://api.example.com:8443/x?y=1"),
            "api.example.com"
        );
        assert_eq!(host_of("not a url"), "not a url");
    }

    /// Serves each canned response to one connection, in order, and returns the request lines.
    fn serve_each(responses: Vec<Vec<u8>>) -> (String, JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            let mut lines = Vec::new();
            for response in responses {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut first = String::new();
                reader.read_line(&mut first).unwrap();
                lines.push(first.trim_end().to_owned());
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    if line.trim_end().is_empty() {
                        break;
                    }
                }
                let mut stream = stream;
                stream.write_all(&response).unwrap();
            }
            lines
        });
        (base, handle)
    }

    #[test]
    fn perform_should_follow_a_loopback_redirect() {
        let (base, server) = serve_each(vec![
            reply("302 Found", "Location: /two\r\n", ""),
            reply("200 OK", "", "arrived"),
        ]);
        let got = perform(plain("GET", &format!("{base}/one"))).unwrap();
        assert_eq!(got.status, 200);
        assert_eq!(got.body, b"arrived");
        let lines = server.join().unwrap();
        assert!(lines[1].starts_with("GET /two "));
    }

    #[test]
    fn perform_should_refuse_a_loopback_redirect_to_another_http_host() {
        let (base, server) = serve_each(vec![reply(
            "302 Found",
            "Location: http://example.com/x\r\n",
            "",
        )]);
        let failed = perform(plain("GET", &format!("{base}/one"))).unwrap_err();
        assert_eq!(failed.kind, "other");
        assert!(failed.reason.contains("refused a redirect"));
        server.join().unwrap();
    }

    #[test]
    fn perform_should_stop_after_ten_redirects() {
        let responses = (0..=MAX_REDIRECTS)
            .map(|_| reply("302 Found", "Location: /again\r\n", ""))
            .collect();
        let (base, server) = serve_each(responses);
        let failed = perform(plain("GET", &format!("{base}/start"))).unwrap_err();
        assert_eq!(failed.kind, "other");
        assert!(failed.reason.contains("more than 10 redirects"));
        assert_eq!(server.join().unwrap().len(), MAX_REDIRECTS + 1);
    }

    #[test]
    fn perform_should_turn_a_303_after_a_post_into_a_get() {
        let (base, server) = serve_each(vec![
            reply("303 See Other", "Location: /done\r\n", ""),
            reply("200 OK", "", "ok"),
        ]);
        let url = format!("{base}/submit");
        let mut call = plain("POST", &url);
        call.payload = Payload::Bytes(b"x".to_vec());
        assert_eq!(perform(call).unwrap().status, 200);
        assert!(server.join().unwrap()[1].starts_with("GET /done "));
    }

    #[test]
    fn check_redirect_should_refuse_https_to_http_and_loopback_to_a_remote_http_host() {
        let uri = |text: &str| text.parse::<Uri>().unwrap();
        assert!(check_redirect(&uri("https://a.example/"), &uri("http://a.example/")).is_err());
        assert!(check_redirect(&uri("https://a.example/"), &uri("https://b.example/")).is_ok());
        assert!(check_redirect(&uri("http://127.0.0.1:1/"), &uri("https://b.example/")).is_ok());
        assert!(check_redirect(&uri("http://127.0.0.1:1/"), &uri("http://[::1]:2/")).is_ok());
        assert!(check_redirect(&uri("http://localhost/"), &uri("http://b.example/")).is_err());
        assert!(check_redirect(&uri("http://a.example/"), &uri("http://b.example/")).is_ok());
        assert!(check_redirect(&uri("http://a.example/"), &uri("ftp://b.example/")).is_err());
    }

    #[test]
    fn resolve_location_should_handle_absolute_rooted_and_relative_values() {
        let base: Uri = "http://h.example:8080/a/b?q=1".parse().unwrap();
        let text = |location: &str| resolve_location(&base, location).unwrap().to_string();
        assert_eq!(text("https://o.example/z"), "https://o.example/z");
        assert_eq!(text("//o.example/z"), "http://o.example/z");
        assert_eq!(text("/z"), "http://h.example:8080/z");
        assert_eq!(text("z"), "http://h.example:8080/a/z");
    }
}

use std::io::{self, IsTerminal, Write};
use std::process::{Child, Command, Stdio};
use std::result::Result as StdResult;
use std::time::Duration;
use std::{env, thread};

use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use mlua::{Lua, LuaString};

use crate::native::term;
use crate::{native_fn, native_struct, overlay, runtime};

/// How long the wait for an external pager sleeps between looks at it.
const POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Spaces a tab turns into, so every character takes one column.
const TAB_WIDTH: usize = 4;

/// Escape text that starts reverse video.
const REVERSE: &str = "\x1b[7m";

/// Escape text that ends reverse video.
const REVERSE_OFF: &str = "\x1b[27m";

/// Escape text that resets every attribute.
const RESET: &str = "\x1b[0m";

native_struct! {
    /// What `dev.term.page` needs to know beyond the text.
    pub struct PageOpts {
        /// Command to run instead of `$PAGER`.
        pub pager: Option<String>,
        /// Rows the screen has.
        pub rows: Option<i64>,
        /// Whether standard output is a terminal.
        pub interactive: Option<bool>,
    }
}

/// A piece of a line: an escape sequence that takes no column, or a character that takes one.
#[derive(Debug, PartialEq, Eq)]
enum Token {
    /// An escape sequence, copied through as it is.
    Escape(String),
    /// A visible character.
    Char(char),
}

/// Which way a search goes and where it starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Search {
    /// A new pattern, which may match the line the search starts on.
    Fresh,
    /// The next match after the current line.
    Next,
    /// The previous match before the current line.
    Previous,
}

/// What a key press asks of the pager.
#[derive(Debug, PartialEq, Eq)]
pub enum Flow {
    /// Keep showing the text.
    Stay,
    /// Leave the pager.
    Quit,
}

/// The state of the built-in pager.
#[derive(Debug)]
pub struct Pager {
    /// The text, one entry per line, tabs expanded.
    lines: Vec<String>,
    /// Index of the first line on screen.
    top: usize,
    /// Index of the line the last search or scroll settled on.
    cursor: usize,
    /// Rows the text takes, one fewer than the screen.
    height: usize,
    /// Columns a line may fill.
    cols: usize,
    /// The search pattern in force.
    query: Option<String>,
    /// The pattern being typed, while the search prompt is open.
    input: Option<String>,
    /// A one-line message for the status row, until the next key.
    notice: Option<String>,
}

/// Splits `line` into escape sequences and visible characters.
#[must_use]
fn tokens(line: &str) -> Vec<Token> {
    let mut out = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(Token::Char(c));
            continue;
        }
        let mut sequence = String::from(c);
        match chars.next() {
            Some('[') => {
                sequence.push('[');
                for next in chars.by_ref() {
                    sequence.push(next);
                    if u8::try_from(next).is_ok_and(|byte| term::CSI_FINAL.contains(&byte)) {
                        break;
                    }
                }
            }
            Some(']') => {
                sequence.push(']');
                while let Some(next) = chars.next() {
                    sequence.push(next);
                    if next == '\x07' {
                        break;
                    }
                    if next == '\x1b' {
                        if let Some(end) = chars.next_if_eq(&'\\') {
                            sequence.push(end);
                        }
                        break;
                    }
                }
            }
            Some(other) => sequence.push(other),
            None => {}
        }
        out.push(Token::Escape(sequence));
    }
    out
}

/// Returns the characters of `line` that take a column.
#[must_use]
fn visible(line: &str) -> Vec<char> {
    tokens(line)
        .into_iter()
        .filter_map(|token| match token {
            Token::Char(c) => Some(c),
            Token::Escape(_) => None,
        })
        .collect()
}

/// Lowercases one character for a case-blind comparison.
#[must_use]
fn fold(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

/// Returns the `(start, end)` column ranges where `query` occurs in `text`.
///
/// The match ignores case unless the query has a capital letter.
#[must_use]
fn find_ranges(text: &[char], query: &str) -> Vec<(usize, usize)> {
    let needle: Vec<char> = query.chars().collect();
    if needle.is_empty() {
        return Vec::new();
    }
    let blind = !query.chars().any(char::is_uppercase);
    let same = |a: char, b: char| if blind { fold(a) == fold(b) } else { a == b };
    let mut found = Vec::new();
    let mut at = 0;
    while at + needle.len() <= text.len() {
        let hit = needle
            .iter()
            .enumerate()
            .all(|(i, &c)| same(text[at + i], c));
        if hit {
            found.push((at, at + needle.len()));
            at += needle.len();
        } else {
            at += 1;
        }
    }
    found
}

/// Cuts `line` to `cols` columns, lighting up `ranges`, and ends it with a reset.
#[must_use]
fn render(line: &str, cols: usize, ranges: &[(usize, usize)]) -> String {
    let mut out = String::new();
    let mut shown = 0;
    let mut lit = false;
    for token in tokens(line) {
        match token {
            Token::Escape(sequence) => {
                let resets = sequence == RESET || sequence == "\x1b[m";
                out.push_str(&sequence);
                if lit && resets {
                    out.push_str(REVERSE);
                }
            }
            Token::Char(c) => {
                if shown >= cols {
                    break;
                }
                if lit && ranges.iter().any(|&(_, end)| end == shown) {
                    out.push_str(REVERSE_OFF);
                    lit = false;
                }
                if ranges.iter().any(|&(start, _)| start == shown) {
                    out.push_str(REVERSE);
                    lit = true;
                }
                out.push(c);
                shown += 1;
            }
        }
    }
    out.push_str(RESET);
    out
}

/// Counts the lines of `text`, a last line without a newline included.
#[must_use]
fn count_lines(text: &[u8]) -> usize {
    let newlines = text.iter().filter(|&&byte| byte == b'\n').count();
    newlines + usize::from(!text.ends_with(b"\n"))
}

impl Pager {
    /// Starts a pager over `text` on a screen of `rows` by `cols`.
    #[must_use]
    pub fn new(text: &str, rows: usize, cols: usize) -> Self {
        let spaces = " ".repeat(TAB_WIDTH);
        Self {
            lines: text
                .lines()
                .map(|line| line.replace('\t', &spaces))
                .collect(),
            top: 0,
            cursor: 0,
            height: rows.saturating_sub(1).max(1),
            cols: cols.max(1),
            query: None,
            input: None,
            notice: None,
        }
    }

    /// Returns the highest line the screen may start at.
    #[must_use]
    fn max_top(&self) -> usize {
        self.lines.len().saturating_sub(self.height)
    }

    /// Measures the screen again after a resize.
    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.height = rows.saturating_sub(1).max(1);
        self.cols = cols.max(1);
        self.top = self.top.min(self.max_top());
    }

    /// Moves the screen `delta` lines, stopping at either end.
    fn scroll(&mut self, delta: isize) {
        let target = self.top.saturating_add_signed(delta);
        self.top = target.min(self.max_top());
        self.cursor = self.top;
    }

    /// Returns the column ranges of the search pattern in line `index`.
    #[must_use]
    fn matches_in(&self, index: usize) -> Vec<(usize, usize)> {
        match (&self.query, self.lines.get(index)) {
            (Some(query), Some(line)) => find_ranges(&visible(line), query),
            _ => Vec::new(),
        }
    }

    /// Moves to the next line that holds the pattern, wrapping around, or says there is none.
    ///
    /// A fresh pattern may match the line the search starts on, a repeat starts after it.
    fn search(&mut self, how: Search) {
        let forward = how != Search::Previous;
        let fresh = how == Search::Fresh;
        let Some(query) = self.query.clone() else {
            self.notice = Some("No search pattern".to_owned());
            return;
        };
        let total = self.lines.len();
        let from = self.cursor;
        let first = usize::from(!fresh);
        let mut order = (first..first + total).map(|step| {
            if forward {
                (from + step) % total
            } else {
                (from + total - step % total) % total
            }
        });
        let found = order.find(|&index| !self.matches_in(index).is_empty());
        match found {
            Some(index) => {
                self.cursor = index;
                self.top = index.min(self.max_top());
            }
            None => self.notice = Some(format!("Pattern not found: {query}")),
        }
    }

    /// Handles a key while the search prompt is open.
    fn on_input(&mut self, key: KeyEvent) -> Flow {
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        let Some(mut input) = self.input.take() else {
            return Flow::Stay;
        };
        match key.code {
            KeyCode::Esc => {}
            KeyCode::Char('c') if control => {}
            KeyCode::Enter => {
                if !input.is_empty() {
                    self.query = Some(input);
                }
                self.search(Search::Fresh);
            }
            KeyCode::Backspace => {
                if input.pop().is_some() {
                    self.input = Some(input);
                }
            }
            KeyCode::Char(c) if !control => {
                input.push(c);
                self.input = Some(input);
            }
            _ => self.input = Some(input),
        }
        Flow::Stay
    }

    /// Applies one key press.
    pub fn on_key(&mut self, key: KeyEvent) -> Flow {
        self.notice = None;
        if self.input.is_some() {
            return self.on_input(key);
        }
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        let page = isize::try_from(self.height).unwrap_or(isize::MAX);
        match key.code {
            KeyCode::Char('c') if control => return Flow::Quit,
            _ if control => {}
            KeyCode::Char('q') | KeyCode::Esc => return Flow::Quit,
            KeyCode::Char('j' | 'e') | KeyCode::Down | KeyCode::Enter => self.scroll(1),
            KeyCode::Char('k' | 'y') | KeyCode::Up => self.scroll(-1),
            KeyCode::Char(' ' | 'f') | KeyCode::PageDown => self.scroll(page),
            KeyCode::Char('b') | KeyCode::PageUp => self.scroll(-page),
            KeyCode::Char('d') => self.scroll(page / 2),
            KeyCode::Char('u') => self.scroll(-(page / 2)),
            KeyCode::Char('g') | KeyCode::Home => self.scroll(isize::MIN / 2),
            KeyCode::Char('G') | KeyCode::End => self.scroll(isize::MAX / 2),
            KeyCode::Char('/') => self.input = Some(String::new()),
            KeyCode::Char('n') => self.search(Search::Next),
            KeyCode::Char('N') => self.search(Search::Previous),
            _ => {}
        }
        Flow::Stay
    }

    /// Returns the status row's text, before it is padded to the screen's width.
    #[must_use]
    fn status(&self) -> String {
        if let Some(input) = &self.input {
            return format!("/{input}");
        }
        if let Some(notice) = &self.notice {
            return notice.clone();
        }
        let total = self.lines.len();
        let last = (self.top + self.height).min(total);
        let place = if last >= total { " (END)" } else { "" };
        format!(
            "lines {}-{last}/{total}{place}  q quit  / search  n next",
            (self.top + 1).min(total),
        )
    }

    /// Returns the escape text that draws the whole screen.
    #[must_use]
    pub fn draw(&self) -> String {
        let mut out = String::new();
        for row in 0..self.height {
            out.push_str(&term::cursor_to(i64::try_from(row + 1).unwrap_or(1), 1));
            out.push_str(term::ERASE_LINE);
            let index = self.top + row;
            if let Some(line) = self.lines.get(index) {
                out.push_str(&render(line, self.cols, &self.matches_in(index)));
            }
        }
        let status: String = self.status().chars().take(self.cols).collect();
        let pad = self.cols.saturating_sub(status.chars().count());
        out.push_str(&format!(
            "{}{}{REVERSE}{status}{}{RESET}",
            term::cursor_to(i64::try_from(self.height + 1).unwrap_or(1), 1),
            term::ERASE_LINE,
            " ".repeat(pad),
        ));
        if self.input.is_some() {
            out.push_str(term::CURSOR_SHOW);
        } else {
            out.push_str(term::CURSOR_HIDE);
        }
        out
    }
}

/// Converts a screen dimension to a count, 1 when it is not positive.
#[must_use]
fn dimension(value: i64) -> usize {
    usize::try_from(value).unwrap_or(1).max(1)
}

/// Shows `text` on the alternate screen until the user quits, leaving it on every way out.
fn run(lua: &Lua, text: &str, rows: i64, cols: i64) -> crate::Result<()> {
    let mut pager = Pager::new(text, dimension(rows), dimension(cols));
    term::enter_alt();
    let result = (|| -> crate::Result<()> {
        term::put(lua, term::ENTER_ALT.as_bytes())?;
        loop {
            term::put(lua, pager.draw().as_bytes())?;
            term::flush(lua)?;
            match term::next_event()? {
                Some(Event::Key(key)) if key.kind != KeyEventKind::Release => {
                    if pager.on_key(key) == Flow::Quit {
                        return Ok(());
                    }
                }
                Some(Event::Resize(cols, rows)) => {
                    pager.resize(usize::from(rows), usize::from(cols));
                }
                Some(_) => {}
                None => return Ok(()),
            }
        }
    })();
    term::leave_alt();
    result
}

/// Splits a pager command on blanks, with no shell and so no quoting.
#[must_use]
fn split_command(command: &str) -> Vec<&str> {
    command.split_whitespace().collect()
}

/// Picks the pager command: the option when it holds a command, else `$PAGER` when it does.
#[must_use]
fn choose_command(option: Option<String>, environment: Option<String>) -> Option<String> {
    option
        .filter(|command| !command.trim().is_empty())
        .or_else(|| environment.filter(|command| !command.trim().is_empty()))
}

/// Pipes `text` through the external pager `command`, returning why it failed.
///
/// A signal that arrives while the pager runs stops it and raises the interrupt.
fn external(lua: &Lua, command: &str, text: &[u8]) -> crate::Result<StdResult<bool, String>> {
    let words = split_command(command);
    let Some((program, args)) = words.split_first() else {
        return Ok(Err("the pager command is empty".to_owned()));
    };
    term::flush(lua)?;
    let mut pager = Command::new(program);
    pager.args(args).stdin(Stdio::piped());
    overlay::apply(&mut pager);
    let spawned = pager.spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => {
            return Ok(Err(
                crate::Error::io(format!("run {program}"), error).to_string()
            ));
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        // A pager that quits early closes the pipe, which is no failure
        let _ = stdin.write_all(text);
    }
    let status = loop {
        if runtime::interrupted() {
            stop(&mut child);
            // The pager is on its way out and its status no longer matters
            let _ = child.wait();
            runtime::check_interrupt().map_err(term::core_error)?;
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => thread::sleep(POLL_INTERVAL),
            Err(error) => {
                return Ok(Err(
                    crate::Error::io(format!("wait for {program}"), error).to_string()
                ));
            }
        }
    };
    Ok(if status.success() {
        Ok(true)
    } else {
        Err(format!("{program} exited with {status}"))
    })
}

/// Asks `child` to stop with SIGTERM, so a pager can restore the screen.
#[cfg(unix)]
fn stop(child: &mut Child) {
    let pid = rustix::process::Pid::from_child(child);
    // The pager may have gone already, which is what was wanted
    let _ = rustix::process::kill_process(pid, rustix::process::Signal::TERM);
}

/// Ends `child`, since Windows has no SIGTERM to ask with.
#[cfg(windows)]
fn stop(child: &mut Child) {
    // The pager may have gone already, which is what was wanted
    let _ = child.kill();
}

native_fn! {
    /// Shows `text` through a pager, or prints it when it fits the screen or is not on a terminal.
    ///
    /// A command in `opts.pager`, else a non-empty `$PAGER`, reads the text on its standard input.
    /// Otherwise the built-in pager shows it: j and k or the arrows scroll, space and b page,
    /// `/` searches, n finds the next match and q quits. Windows has no built-in pager and
    /// prints the text when no pager command is set. Returns true when a pager showed the
    /// text, false when it was printed, and `nil` with a reason when an external pager failed.
    ///
    /// # Errors
    ///
    /// Raises when the standard output buffer fails.
    pub fn page(
        lua: &Lua,
        text: LuaString,
        opts: Option<PageOpts>,
    ) -> mlua::Result<StdResult<bool, String>> {
        let bytes = text.as_bytes();
        let (pager, rows, interactive) = opts.map_or((None, None, None), |opts| {
            (opts.pager, opts.rows, opts.interactive)
        });
        let (measured_rows, cols) = term::measure();
        let rows = rows.unwrap_or(measured_rows);
        let interactive = interactive.unwrap_or_else(|| io::stdout().is_terminal());
        let fits = i64::try_from(count_lines(&bytes)).is_ok_and(|lines| lines <= rows);
        if !interactive || fits {
            runtime::write_out(lua, &bytes)?;
            return Ok(Ok(false));
        }
        let command = choose_command(pager, env::var("PAGER").ok());
        if let Some(command) = command {
            return Ok(external(lua, &command, &bytes)?);
        }
        if cfg!(windows) {
            runtime::write_out(lua, &bytes)?;
            return Ok(Ok(false));
        }
        runtime::flush_out(lua)?;
        let Ok(entered) = term::enter_raw() else {
            runtime::write_out(lua, &bytes)?;
            return Ok(Ok(false));
        };
        let result = run(lua, &String::from_utf8_lossy(&bytes), rows, cols);
        if entered {
            term::leave_raw();
        }
        result?;
        Ok(Ok(true))
    }
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::{
        Flow, Pager, choose_command, count_lines, find_ranges, render, split_command, tokens,
        visible,
    };

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn numbered(count: usize) -> String {
        (1..=count).map(|n| format!("line {n}\n")).collect()
    }

    #[test]
    fn count_lines_should_count_an_unterminated_last_line() {
        assert_eq!(count_lines(b"a\nb\n"), 2);
        assert_eq!(count_lines(b"a\nb"), 2);
    }

    #[test]
    fn render_should_cut_at_the_width_and_keep_colour() {
        let line = "\x1b[31mabcdef\x1b[0m";
        assert_eq!(render(line, 3, &[]), "\x1b[31mabc\x1b[0m");
    }

    #[test]
    fn render_should_light_up_a_match() {
        let out = render("find me", 20, &[(5, 7)]);
        assert_eq!(out, "find \x1b[7mme\x1b[0m");
    }

    #[test]
    fn find_ranges_should_ignore_case_unless_the_query_has_a_capital() {
        let text: Vec<char> = "Foo foo".chars().collect();
        assert_eq!(find_ranges(&text, "foo"), [(0, 3), (4, 7)]);
        assert_eq!(find_ranges(&text, "Foo"), [(0, 3)]);
    }

    #[test]
    fn visible_should_skip_escape_sequences() {
        let text = visible("\x1b[1mbo\x1b[0mld");
        assert_eq!(text.into_iter().collect::<String>(), "bold");
    }

    #[test]
    fn on_key_should_scroll_and_stop_at_the_ends() {
        let mut pager = Pager::new(&numbered(30), 11, 40);
        pager.on_key(press(KeyCode::Char('j')));
        assert_eq!(pager.top, 1);
        pager.on_key(press(KeyCode::Char(' ')));
        assert_eq!(pager.top, 11);
        pager.on_key(press(KeyCode::End));
        assert_eq!(pager.top, 20);
        pager.on_key(press(KeyCode::Char('b')));
        assert_eq!(pager.top, 10);
        pager.on_key(press(KeyCode::Home));
        assert_eq!(pager.top, 0);
    }

    #[test]
    fn on_key_should_quit_on_q() {
        let mut pager = Pager::new(&numbered(30), 11, 40);
        assert_eq!(pager.on_key(press(KeyCode::Char('q'))), Flow::Quit);
    }

    #[test]
    fn on_key_should_search_and_find_the_next_match() {
        let mut pager = Pager::new(&numbered(30), 11, 40);
        pager.on_key(press(KeyCode::Char('/')));
        for c in "line 2".chars() {
            pager.on_key(press(KeyCode::Char(c)));
        }
        pager.on_key(press(KeyCode::Enter));
        assert_eq!(pager.top, 1);
        pager.on_key(press(KeyCode::Char('n')));
        assert_eq!(pager.cursor, 19);
        assert!(pager.draw().contains("\x1b[7mline 2\x1b[27m0"));
    }

    #[test]
    fn on_key_should_report_a_missing_pattern() {
        let mut pager = Pager::new(&numbered(30), 11, 60);
        pager.on_key(press(KeyCode::Char('/')));
        for c in "zzz".chars() {
            pager.on_key(press(KeyCode::Char(c)));
        }
        pager.on_key(press(KeyCode::Enter));
        assert!(pager.draw().contains("Pattern not found: zzz"));
    }

    #[test]
    fn draw_should_fill_the_screen_and_end_with_a_status_row() {
        let pager = Pager::new(&numbered(30), 11, 60);
        let screen = pager.draw();
        assert!(screen.contains("line 10"));
        assert!(!screen.contains("line 11"));
        assert!(screen.contains("lines 1-10/30"));
    }

    #[test]
    fn tokens_should_treat_an_osc_link_as_zero_width() {
        let line = "\x1b]8;;http://x\x07link\x1b]8;;\x1b\\!";
        assert_eq!(visible(line).into_iter().collect::<String>(), "link!");
        assert_eq!(tokens(line).len(), 7);
    }

    #[test]
    fn render_should_keep_a_match_lit_across_a_colour_reset() {
        let out = render("a\x1b[1mb\x1b[0mc", 20, &[(0, 3)]);
        assert_eq!(out, "\x1b[7ma\x1b[1mb\x1b[0m\x1b[7mc\x1b[0m");
    }

    #[test]
    fn on_key_should_search_text_that_holds_colour_codes() {
        let mut pager = Pager::new("one\n\x1b[31mtw\x1b[0mo\nthree\n", 3, 40);
        pager.on_key(press(KeyCode::Char('/')));
        for c in "two".chars() {
            pager.on_key(press(KeyCode::Char(c)));
        }
        pager.on_key(press(KeyCode::Enter));
        assert_eq!(pager.cursor, 1);
    }

    #[test]
    fn on_key_should_find_a_fresh_pattern_on_the_line_the_search_starts_on() {
        let mut pager = Pager::new("hit\nmiss\nmiss\n", 4, 40);
        pager.on_key(press(KeyCode::Char('/')));
        for c in "hit".chars() {
            pager.on_key(press(KeyCode::Char(c)));
        }
        pager.on_key(press(KeyCode::Enter));
        assert_eq!(pager.cursor, 0);
    }

    #[test]
    fn choose_command_should_prefer_the_option_and_skip_blank_values() {
        let some = |text: &str| Some(text.to_owned());
        assert_eq!(choose_command(some("less"), some("more")), some("less"));
        assert_eq!(choose_command(None, some("more")), some("more"));
        assert_eq!(choose_command(some("  "), some("more")), some("more"));
        assert_eq!(choose_command(None, some("")), None);
        assert_eq!(choose_command(None, None), None);
    }

    #[test]
    fn split_command_should_split_on_blanks_and_keep_quotes() {
        assert_eq!(split_command("less  -R"), ["less", "-R"]);
        assert_eq!(split_command("sh -c 'a b'"), ["sh", "-c", "'a", "b'"]);
    }
}

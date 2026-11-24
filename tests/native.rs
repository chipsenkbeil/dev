use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::{env, fs};

/// Suffix of a Luau file the harness runs as one suite.
const SUITE_SUFFIX: &str = "_test.luau";

/// Exit status `dev -l` gives a usage error.
const USAGE_EXIT: i32 = 2;

/// Exit status `dev -l` gives a file that raised an error.
const FAILURE_EXIT: i32 = 1;

/// Exit status dev gives once the reader of its output has gone, as a kill by SIGPIPE gives.
const BROKEN_PIPE_EXIT: i32 = 141;

#[must_use]
fn native_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("native")
}

#[must_use]
fn fixture(name: &str) -> String {
    native_dir()
        .join("fixtures")
        .join(name)
        .display()
        .to_string()
}

/// Runs the built dev with `args` from a folder outside the repo, so nothing reads the tree.
fn dev(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_dev"))
        .env_remove("DEV_REMOTE")
        .env_remove("VERBOSE")
        .args(args)
        .current_dir(env::temp_dir())
        .output()
        .expect("the built dev should start")
}

#[must_use]
fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn every_native_suite_should_pass() {
    let mut suites: Vec<PathBuf> = fs::read_dir(native_dir())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.to_string_lossy().ends_with(SUITE_SUFFIX))
        .collect();
    suites.sort();
    assert!(!suites.is_empty());

    // Run each suite on its own and report every failure, not only the first
    let mut failed = Vec::new();
    for suite in &suites {
        let output = dev(&["-l", &suite.display().to_string()]);
        print!("{}", text(&output.stdout));
        eprint!("{}", text(&output.stderr));
        if !output.status.success() {
            failed.push(format!("{} ({})", suite.display(), output.status));
        }
    }
    assert!(failed.is_empty(), "failed suites: {failed:?}");
}

#[test]
fn script_should_get_its_arguments_in_arg() {
    let file = fixture("args.luau");
    let output = dev(&["-l", &file, "a", "b c"]);
    assert_eq!(text(&output.stdout), format!("{file}\na\tb c\n2\ta\tb c\n"));
    assert!(output.status.success(), "{}", text(&output.stderr));
}

#[test]
fn script_should_exit_1_with_a_traceback_on_a_runtime_error() {
    let output = dev(&["-l", &fixture("raise.luau")]);
    assert_eq!(output.status.code(), Some(FAILURE_EXIT));
    let stderr = text(&output.stderr);
    assert!(stderr.starts_with("dev: "), "{stderr}");
    assert!(
        stderr.contains("raise.luau:2: the fixture failed"),
        "{stderr}"
    );
    assert!(stderr.contains("stack traceback:"), "{stderr}");
}

#[test]
fn script_should_exit_2_for_a_missing_file() {
    let output = dev(&["-l", "/no/such/file.luau"]);
    assert_eq!(output.status.code(), Some(USAGE_EXIT));
    assert_eq!(
        text(&output.stderr),
        "The file /no/such/file.luau does not exist.\n"
    );
}

#[test]
fn exit_should_run_the_cleanups_newest_first_once() {
    let output = dev(&["-l", &fixture("cleanups.luau")]);
    assert_eq!(output.status.code(), Some(3));
    assert_eq!(text(&output.stdout), "body\nsecond\nfirst\n");
    assert_eq!(text(&output.stderr), "A cleanup failed: cleanup broke.\n");
}

#[test]
fn print_should_join_values_with_tabs_through_tostring() {
    let output = dev(&["-l", &fixture("print.luau")]);
    assert_eq!(text(&output.stdout), "1\tnil\ttrue\tshown\n");
    assert!(output.status.success());
}

#[test]
fn output_should_end_dev_with_141_and_no_message_once_the_reader_is_gone() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_dev"))
        .args(["-l", &fixture("flood.luau")])
        .current_dir(env::temp_dir())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the built dev should start");
    let mut reader = BufReader::new(child.stdout.take().expect("stdout should be piped"));
    let mut first = String::new();
    reader
        .read_line(&mut first)
        .expect("dev should print a first line");
    assert_eq!(first, "1\n");
    drop(reader);

    let output = child.wait_with_output().expect("dev should end");
    assert_eq!(output.status.code(), Some(BROKEN_PIPE_EXIT));
    assert_eq!(text(&output.stderr), "");
}

#[test]
fn global_flags_should_refuse_an_unknown_flag_and_a_folder_dev_cannot_enter() {
    let output = dev(&["--bogus", "test"]);
    assert_eq!(output.status.code(), Some(USAGE_EXIT));
    assert_eq!(
        text(&output.stderr),
        "The flag `--bogus` is not a global flag of dev.\n"
    );

    let output = dev(&["-C", "/no/such/folder", "-l", &fixture("args.luau")]);
    assert_eq!(output.status.code(), Some(USAGE_EXIT));
    assert_eq!(
        text(&output.stderr),
        "The flag `-C` cannot enter /no/such/folder.\n"
    );
}

#[test]
fn global_flags_should_enter_each_folder_and_reach_a_script_through_dev_globals() {
    let fixtures = native_dir().join("fixtures").display().to_string();
    let output = dev(&[
        "-vvv",
        "-C",
        "/",
        "-C",
        &fixtures[1..],
        "-l",
        "globals.luau",
        "a",
    ]);
    let version = env!("CARGO_PKG_VERSION");
    assert_eq!(text(&output.stdout), format!("3\t0\tfalse\t{version}\n"));
    assert_eq!(text(&output.stderr), "+ dev.runtime.assets\n");
    assert!(output.status.success());
}

#[test]
fn log_should_show_each_level_from_its_verbosity_and_never_touch_stdout() {
    let log = fixture("log.luau");
    let cases = [
        (vec!["-q"], "error: e\n", "out\t0\ttrue\tfalse\tfalse\n"),
        (
            vec![],
            "error: e\nwarning: w\ni\n",
            "out\t0\tfalse\tfalse\tfalse\n",
        ),
        (
            vec!["-v"],
            "error: e\nwarning: w\ni\ndebug: d\n",
            "out\t1\tfalse\ttrue\tfalse\n",
        ),
        (
            vec!["-q", "-vv"],
            "error: e\nwarning: w\ni\ndebug: d\n+ t\n",
            "out\t2\tfalse\ttrue\tfalse\n",
        ),
    ];
    for (flags, stderr, stdout) in cases {
        let mut args = flags.clone();
        args.extend(["-l", &log]);
        let output = dev(&args);
        assert_eq!(text(&output.stderr), stderr, "{flags:?}");
        assert_eq!(text(&output.stdout), stdout, "{flags:?}");
        assert!(output.status.success());
    }
}

#[test]
fn log_should_fall_back_to_verbose_and_let_q_override_it() {
    let log = fixture("log.luau");
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_dev"))
            .env("VERBOSE", "1")
            .args(args)
            .current_dir(env::temp_dir())
            .output()
            .expect("the built dev should start")
    };
    assert_eq!(
        text(&run(&["-l", &log]).stdout),
        "out\t1\tfalse\ttrue\tfalse\n"
    );
    assert_eq!(
        text(&run(&["-q", "-l", &log]).stdout),
        "out\t0\ttrue\tfalse\tfalse\n"
    );
}

#[test]
fn verbosity_4_should_trace_calls_between_luau_modules() {
    let output = dev(&["-vvvv", "-l", &fixture("calls.luau")]);
    assert_eq!(text(&output.stdout), "2\tcalls\ttrue\n");
    assert_eq!(
        text(&output.stderr),
        "+ dev.runtime.assets\n+ calls.one\n+ calls.twice\n"
    );
    let quiet = dev(&["-vvv", "-l", &fixture("calls.luau")]);
    assert_eq!(text(&quiet.stdout), "2\tcalls\ttrue\n");
    assert_eq!(text(&quiet.stderr), "+ dev.runtime.assets\n");
}

/// Folders whose `.luau` files must all compile: what dev embeds, and the Luau test suites.
const LUAU_ROOTS: [&str; 3] = ["luau", "init", "tests"];

/// Adds every `.luau` file under `dir` to `files`, recursing into folders.
fn luau_files(dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for path in entries.map(|entry| entry.expect("a folder entry should read").path()) {
        if path.is_dir() {
            luau_files(&path, files);
        } else if path.extension().is_some_and(|ext| ext == "luau") {
            files.push(path);
        }
    }
}

#[test]
fn every_luau_file_should_compile() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    for name in LUAU_ROOTS {
        luau_files(&root.join(name), &mut files);
    }
    files.sort();
    assert!(!files.is_empty());

    // Compile each file without running it, and name every one that fails
    let lua = dev::runtime::new().expect("the Luau state should start");
    let mut failed = Vec::new();
    for path in &files {
        let source = fs::read(path).expect("a Luau file should read");
        let name = path
            .strip_prefix(root)
            .unwrap_or(path)
            .display()
            .to_string();
        if let Err(error) = dev::runtime::load(&lua, &source, &format!("@{name}"), None) {
            failed.push(dev::runtime::message(&error));
        }
    }
    assert!(
        failed.is_empty(),
        "{} of {} Luau files do not compile:\n{}",
        failed.len(),
        files.len(),
        failed.join("\n")
    );
}

#[test]
fn script_should_reach_the_dev_lib_of_its_project_and_exit_with_what_it_returns() {
    let output = dev(&["-l", &fixture("project/tests/uses_lib.luau")]);
    assert_eq!(output.status.code(), Some(3), "{}", text(&output.stderr));
}

#[test]
fn script_should_run_the_cases_it_registered_and_exit_1_when_one_fails() {
    let output = dev(&["-l", &fixture("project/tests/cases.luau")]);
    assert_eq!(output.status.code(), Some(FAILURE_EXIT));
    let stdout = text(&output.stdout);
    assert!(
        stdout.contains("ok - the project library loads"),
        "{stdout}"
    );
    assert!(
        stdout.contains("not ok - a failing case fails the run"),
        "{stdout}"
    );
}

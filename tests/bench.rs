use std::time::{Duration, Instant};

use mlua::Lua;

/// Iterations of each workload loop.
const ITERATIONS: u32 = 20_000_000;

/// Timed runs of each workload, of which the fastest counts.
const RUNS: usize = 5;

/// Luau workloads, each a loop of `n` iterations: arithmetic, and a Luau function call.
const WORKLOADS: [(&str, &str); 2] = [
    (
        "arithmetic loop",
        "local n = ... local s = 0 for i = 1, n do s += i % 7 end return s",
    ),
    (
        "function call loop",
        "local n = ... local function f(x) return x + 1 end local s = 0 for i = 1, n do s = f(s) end return s",
    ),
];

/// Returns the fastest of [`RUNS`] runs of `source` in `lua`.
fn fastest(lua: &Lua, source: &str) -> Duration {
    let chunk = lua
        .load(source)
        .into_function()
        .expect("the workload should compile");
    (0..RUNS)
        .map(|_| {
            let start = Instant::now();
            chunk
                .call::<f64>(ITERATIONS)
                .expect("the workload should run");
            start.elapsed()
        })
        .min()
        .expect("there is at least one run")
}

#[test]
#[ignore = "a benchmark, run by the bench ci job in release mode"]
fn interrupt_hook_should_cost_little_per_iteration() {
    let hooked = dev::runtime::new().expect("dev's Luau state should start");
    let plain = Lua::new();
    for (name, source) in WORKLOADS {
        let with_hook = fastest(&hooked, source);
        let without = fastest(&plain, source);
        let per = |time: Duration| time.as_secs_f64() * 1e9 / f64::from(ITERATIONS);
        println!(
            "{name}: {:.2} ns/iteration with the hook, {:.2} without, {:+.1}%",
            per(with_hook),
            per(without),
            (per(with_hook) / per(without) - 1.0) * 100.0
        );
    }
}

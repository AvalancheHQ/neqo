// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

//! Cross-implementation QUIC performance comparison benchmarks.
//!
//! Mirrors the perfcompare jobs in `.github/workflows/codspeed.yml`.
//! Each benchmark:
//!   1. Starts the server process
//!   2. Runs the client command N times (the measured part)
//!   3. Kills the server process
//!
//! Environment variables consumed (set by the workflow):
//!   - `{COMBO}_SERVER_CMD` — full server command line
//!   - `{COMBO}_CLIENT_CMD` — full client command line
//!
//! Where `{COMBO}` is one of:
//!   `QUICHE_QUICHE`, `GOOGLE_NEQO`, `QUICHE_NEQO`

#![expect(clippy::unwrap_used, reason = "OK in a bench.")]

use std::{
    env,
    process::{Child, Command, Stdio},
    thread,
    time::Duration,
};

use criterion::{Criterion, criterion_group, criterion_main};

fn parse_cmd(cmd: &str) -> (String, Vec<String>) {
    let mut words =
        shell_words::split(cmd).unwrap_or_else(|e| panic!("invalid command `{cmd}`: {e}"));
    assert!(!words.is_empty(), "empty command");
    let prog = words.remove(0);
    (prog, words)
}

struct PerfBench {
    name: &'static str,
    server_env: &'static str,
    client_env: &'static str,
}

const BENCHMARKS: &[PerfBench] = &[
    PerfBench {
        name: "quiche-quiche",
        server_env: "QUICHE_QUICHE_SERVER_CMD",
        client_env: "QUICHE_QUICHE_CLIENT_CMD",
    },
    PerfBench {
        name: "google-neqo",
        server_env: "GOOGLE_NEQO_SERVER_CMD",
        client_env: "GOOGLE_NEQO_CLIENT_CMD",
    },
    PerfBench {
        name: "quiche-neqo",
        server_env: "QUICHE_NEQO_SERVER_CMD",
        client_env: "QUICHE_NEQO_CLIENT_CMD",
    },
];

fn spawn_cmd(cmd: &str) -> Child {
    let (prog, args) = parse_cmd(cmd);
    Command::new(prog)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn `{cmd}`: {e}"))
}

fn port_is_bound(port: u16) -> bool {
    // Check /proc/net/udp and /proc/net/udp6 for the port in hex.
    let hex_port = format!("{port:04X}");
    for path in ["/proc/net/udp", "/proc/net/udp6"] {
        if let Ok(contents) = std::fs::read_to_string(path) {
            for line in contents.lines().skip(1) {
                if let Some(addr_field) = line.split_whitespace().nth(1) {
                    if addr_field.ends_with(&format!(":{hex_port}")) {
                        return true;
                    }
                }
            }
        }
    }
    false
}

fn start_server(cmd: &str) -> Child {
    let mut child = spawn_cmd(cmd);

    thread::sleep(Duration::from_secs(3));

    match child.try_wait() {
        Ok(Some(status)) => panic!("server exited prematurely with {status}: `{cmd}`"),
        Ok(None) => {}
        Err(e) => panic!("failed to poll server process: {e}"),
    }

    if !port_is_bound(4433) {
        let _ = child.kill();
        let _ = child.wait();
        panic!("server is not listening on UDP port 4433 after 3 s: `{cmd}`");
    }

    child
}

fn stop_server(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn perfcompare(c: &mut Criterion) {
    // Match the CodSpeed exec-harness min-rounds: 150.
    let mut group = c.benchmark_group("perfcompare");
    group.sample_size(150);

    for bench in BENCHMARKS {
        let (Ok(server_cmd), Ok(client_cmd)) =
            (env::var(bench.server_env), env::var(bench.client_env))
        else {
            continue;
        };

        // 1. Setup: start the server.
        let server = start_server(&server_cmd);

        // 2. Benchmark: run the client command.
        group.bench_function(format!("criterion-{}", bench.name), |b| {
            b.iter(|| {
                let (prog, args) = parse_cmd(&client_cmd);
                let status = Command::new(prog)
                    .args(args)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .unwrap_or_else(|e| panic!("failed to run client: {e}"));
                assert!(status.success(), "client exited with {status}");
            });
        });

        // 3. Cleanup: stop the server.
        stop_server(server);
    }

    group.finish();
}

criterion_group!(benches, perfcompare);
criterion_main!(benches);

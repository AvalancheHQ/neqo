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

fn spawn_shell(cmd: &str) -> Child {
    Command::new("sh")
        .args(["-c", cmd])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn `{cmd}`: {e}"))
}

fn start_server(cmd: &str) -> Child {
    let child = spawn_shell(cmd);
    // Give the server time to bind its socket, same as the workflow's `sleep 1`.
    thread::sleep(Duration::from_secs(1));
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
                let status = Command::new("sh")
                    .args(["-c", &client_cmd])
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

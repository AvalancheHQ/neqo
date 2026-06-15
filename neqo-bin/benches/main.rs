// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

#![expect(clippy::unwrap_used, reason = "OK in a bench.")]
#![expect(
    clippy::significant_drop_tightening,
    reason = "Inherent in codspeed criterion_group! macro."
)]

use std::{env, hint::black_box, net::SocketAddr, time::Duration};

use criterion::{BatchSize, Criterion, Throughput, criterion_group, criterion_main};
use neqo_bin::{client, server};
use tokio::runtime::Builder;

struct Benchmark {
    name: &'static str,
    num_requests: usize,
    upload_size: usize,
    download_size: usize,
}

/// Returns the CPUs this process is allowed to run on (its affinity mask). On a
/// CodSpeed macro runner this is the dedicated benchmark die (e.g. cores 8-15).
#[cfg(target_os = "linux")]
fn current_affinity() -> Vec<usize> {
    // SAFETY: `set` is zero-initialized and sized correctly for the call.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        if libc::sched_getaffinity(0, size_of::<libc::cpu_set_t>(), &mut set) != 0 {
            return Vec::new();
        }
        (0..libc::CPU_SETSIZE as usize)
            .filter(|&cpu| libc::CPU_ISSET(cpu, &set))
            .collect()
    }
}

/// Pins the calling thread to a single CPU. Best-effort: errors are ignored.
#[cfg(target_os = "linux")]
fn pin_current_thread(cpu: usize) {
    // SAFETY: `set` is zero-initialized and sized correctly for the call.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, size_of::<libc::cpu_set_t>(), &set);
    }
}

#[cfg(not(target_os = "linux"))]
fn current_affinity() -> Vec<usize> {
    Vec::new()
}

#[cfg(not(target_os = "linux"))]
fn pin_current_thread(_cpu: usize) {}

/// Picks distinct CPUs to pin the server and client threads to, returning
/// `(server_cpu, client_cpu)`.
///
/// Honors the `NEQO_BENCH_SERVER_CPU` / `NEQO_BENCH_CLIENT_CPU` env vars when
/// set; otherwise picks the two highest CPUs from the process's affinity mask
/// (the dedicated benchmark cores). Returns `None` when fewer than two distinct
/// CPUs are available, in which case threads are left unpinned.
fn bench_cpus() -> Option<(usize, usize)> {
    let env_cpu = |name| env::var(name).ok().and_then(|v| v.parse::<usize>().ok());
    let cpus = current_affinity();
    let server = env_cpu("NEQO_BENCH_SERVER_CPU").or_else(|| cpus.last().copied())?;
    let client = env_cpu("NEQO_BENCH_CLIENT_CPU")
        .or_else(|| cpus.iter().rev().find(|&&c| c != server).copied())?;
    (server != client).then_some((server, client))
}

fn transfer(c: &mut Criterion) {
    test_fixture::fixture_init();

    // Pin the client (this) thread and the server thread to distinct dedicated
    // cores so they don't migrate or contend during measurement. This mostly
    // matters for the RPS/HPS benches; the large transfers are less sensitive.
    let server_cpu = match bench_cpus() {
        Some((server, client)) => {
            eprintln!(
                "[bench] pinning client thread to CPU {client}, server thread to CPU {server}"
            );
            pin_current_thread(client);
            Some(server)
        }
        None => None,
    };

    let mtu_suffix = env::var("MTU").ok().map(|mtu| format!("/mtu-{mtu}"));
    for Benchmark {
        name,
        num_requests,
        upload_size,
        download_size,
    } in [
        Benchmark {
            name: "1-conn/1-100mb-resp (aka. Download)",
            num_requests: 1,
            upload_size: 0,
            download_size: 100 * 1024 * 1024,
        },
        Benchmark {
            name: "1-conn/10_000-parallel-1b-resp (aka. RPS)",
            num_requests: 10_000,
            upload_size: 0,
            download_size: 1,
        },
        Benchmark {
            name: "1-conn/1-1b-resp (aka. HPS)",
            num_requests: 1,
            upload_size: 0,
            download_size: 1,
        },
        Benchmark {
            name: "1-conn/1-100mb-req (aka. Upload)",
            num_requests: 1,
            upload_size: 100 * 1024 * 1024,
            download_size: 0,
        },
    ] {
        let bench_name = mtu_suffix
            .as_ref()
            .map_or_else(|| name.to_string(), |suffix| format!("{name}{suffix}"));
        let mut group = c.benchmark_group("transfer");
        group.throughput(if num_requests == 1 {
            Throughput::Bytes((upload_size + download_size) as u64)
        } else {
            Throughput::Elements(num_requests as u64)
        });
        group.bench_function(&bench_name, |b| {
            b.to_async(Builder::new_current_thread().enable_all().build().unwrap())
                .iter_batched(
                    || {
                        let (server_handle, server_addr) = spawn_server(server_cpu);
                        let client = client::client(client::Args::new(
                            Some(server_addr),
                            num_requests,
                            upload_size,
                            download_size,
                        ));
                        (server_handle, client)
                    },
                    |(server_handle, client)| {
                        black_box(async move {
                            client.await.unwrap();
                            // Tell server to shut down.
                            server_handle.send(()).unwrap();
                        })
                    },
                    BatchSize::PerIteration,
                );
        });
        group.finish();
    }
}

fn spawn_server(pin_cpu: Option<usize>) -> (tokio::sync::oneshot::Sender<()>, SocketAddr) {
    let (done_sender, mut done_receiver) = tokio::sync::oneshot::channel();
    let (addr_sender, addr_receiver) = std::sync::mpsc::channel::<SocketAddr>();
    std::thread::spawn(move || {
        if let Some(cpu) = pin_cpu {
            pin_current_thread(cpu);
        }
        let runtime = Builder::new_current_thread().enable_all().build().unwrap();

        let mut args = server::Args::default();
        args.set_hosts(vec!["[::]:0".to_string()]);
        // `server.run` calls tokio's `UdpSocket::from_std` which requires a
        // Tokio runtime. Ensure one is available by running it in
        // `runtime.block_on`.
        let (server, local_addrs) = runtime.block_on(async { server::run(args).unwrap() });

        addr_sender
            .send(local_addrs.into_iter().find(SocketAddr::is_ipv6).unwrap())
            .unwrap();

        runtime.block_on(async {
            let mut server = Box::pin(server);
            tokio::select! {
                _ = &mut done_receiver => {}
                res = &mut server  => panic!("expect server not to terminate: {res:?}"),
            };
        });
    });
    (done_sender, addr_receiver.recv().unwrap())
}

criterion_group! {
    name = benches;
    // Longer warm-up and measurement than Criterion's 3s/5s defaults: the
    // throughput benches could not fit 100 samples into the default 5s window
    // (Criterion warned, e.g. RPS needed ~12.8s), which widened their
    // confidence intervals. Matches the configuration used by the
    // transfer_walltime bench.
    config = Criterion::default()
        .warm_up_time(Duration::from_secs(5))
        .measurement_time(Duration::from_secs(15));
    targets = transfer
}
criterion_main!(benches);

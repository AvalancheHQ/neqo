#!/usr/bin/env bash
# Run CodSpeed benchmarks locally, mirroring the codspeed.yml workflow.
# Usage: ./run-codspeed.sh [--workspace DIR]
set -euo pipefail

WORKSPACE="${1:-$PWD}"
TRANSFER_SIZE=33554432  # 32 MiB
HOST=127.0.0.1
PORT=4433
TESTDATA="$WORKSPACE/testdata"

NEQO="$WORKSPACE/artifacts/build-neqo"
GOOGLE="$WORKSPACE/artifacts/build-google"
QUICHE="$WORKSPACE/artifacts/build-quiche"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "::error::$*" >&2; exit 1; }

tune_sysfs() {
  local file="$1" desired="$2" desc="$3" skip="${4:-}"
  [ -f "$file" ] || return 0
  local current
  current=$(cat "$file" 2>/dev/null) || return 0
  if [ -n "$skip" ]; then
    if [[ "$current" =~ $skip ]]; then
      echo "$desc: already ok ($current)"
      return 0
    fi
  elif [ "$current" = "$desired" ]; then
    echo "$desc: already set to $desired"
    return 0
  fi
  if ! echo "$desired" | sudo tee "$file" > /dev/null 2>&1; then
    echo "::warning::$desc: failed to set $desired (current: $current)"
  fi
}

select_cpus() {
  declare -A core_to_cpu
  for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu=$(basename "$cpu_path")
    cpu_num=${cpu#cpu}
    core_id_file="$cpu_path/topology/core_id"
    if [ -f "$core_id_file" ]; then
      core_id=$(cat "$core_id_file")
      if [ -z "${core_to_cpu[$core_id]:-}" ]; then
        core_to_cpu[$core_id]=$cpu_num
      fi
    fi
  done
  mapfile -t physical_cpus < <(printf '%s\n' "${core_to_cpu[@]}")
  mapfile -t sorted < <(printf '%s\n' "${physical_cpus[@]}" | sort -rn)
  if [ ${#sorted[@]} -ge 2 ]; then
    SERVER_CPU=${sorted[0]}
    CLIENT_CPU=${sorted[1]}
  elif [ ${#sorted[@]} -eq 1 ]; then
    SERVER_CPU=${sorted[0]}
    CLIENT_CPU=${sorted[0]}
    echo "::warning::Only one physical core, server and client share CPU $SERVER_CPU"
  else
    SERVER_CPU=0
    CLIENT_CPU=1
    echo "::warning::Could not determine physical cores, using CPUs 0 and 1"
  fi
  echo "Selected SERVER_CPU=$SERVER_CPU, CLIENT_CPU=$CLIENT_CPU"
}

# Generate server + client commands for a given pair.
# Sets: BENCH_NAME, SERVER_CMD, CLIENT_CMD
gen_commands() {
  local client="$1" server="$2" cubic="${3:-true}" pacing="${4:-true}"
  local name="$client-$server"

  local cc interop neqo_args
  cc=$([[ "$cubic" == "true" ]] && echo "cubic" || echo "newreno")
  neqo_args="--cc $cc -Q 1"
  [[ "$pacing" != "true" ]] && neqo_args="$neqo_args --no-pacing"

  interop=""
  if [[ "$client" == "s2n" || "$server" == "s2n" || "$client" == "msquic" || "$server" == "msquic" ]]; then
    interop="-a hq-interop"
  fi

  if [[ "$client" == "neqo" && "$server" == "neqo" ]]; then
    name="$name-$cc"
    [[ "$pacing" != "true" ]] && name="$name-nopacing"
  fi

  case "$server" in
    neqo)   SERVER_CMD="$NEQO/neqo-server $neqo_args $interop $HOST:$PORT" ;;
    google) SERVER_CMD="$GOOGLE/quic_server --generate_dynamic_responses --port $PORT --certificate_file $TESTDATA/cert --key_file $TESTDATA/key" ;;
    quiche) SERVER_CMD="$QUICHE/quiche-server --root $TESTDATA --listen $HOST:$PORT --cert $TESTDATA/cert --key $TESTDATA/key" ;;
    *) die "Unknown server: $server" ;;
  esac

  case "$client" in
    neqo)   CLIENT_CMD="$NEQO/neqo-client $neqo_args $interop --output-dir . https://$HOST:$PORT/$TRANSFER_SIZE" ;;
    google) CLIENT_CMD="bash -c '$GOOGLE/quic_client --disable_certificate_verification https://$HOST:$PORT/$TRANSFER_SIZE > $TRANSFER_SIZE'" ;;
    quiche) CLIENT_CMD="$QUICHE/quiche-client --no-verify --dump-responses . https://$HOST:$PORT/$TRANSFER_SIZE" ;;
    *) die "Unknown client: $client" ;;
  esac

  BENCH_NAME="$name"
}

start_server() {
  local label="$1"
  kill_port
  # shellcheck disable=SC2086
  taskset -c "$SERVER_CPU" $SERVER_CMD &
  SERVER_PID=$!
  sleep 3
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    die "Server ($label) exited prematurely"
  fi
  if ! ss -ulnp | grep -q ":$PORT "; then
    kill "$SERVER_PID" 2>/dev/null || true
    die "Server ($label) is not listening on UDP port $PORT"
  fi
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

kill_port() {
  # Kill any process already listening on UDP $PORT so re-runs don't fail.
  local pids
  pids=$(ss -ulnp "sport = :$PORT" | awk 'NR>1 && /pid=/{match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}')
  for pid in $pids; do
    echo "Killing stale process $pid on UDP port $PORT"
    kill "$pid" 2>/dev/null || true
  done
  # Give the OS a moment to release the port.
  sleep 1
}

run_bench() {
  local label="$1" min_rounds="$2"
  echo "--- Running benchmark: $BENCH_NAME ($label, min-rounds=$min_rounds) ---"

  # The config written here mirrors what the workflow passes to CodSpeedHQ/action.
  cat > "$WORKSPACE/codspeed.yml" <<EOF
benchmarks:
  - name: "$BENCH_NAME"
    exec: taskset -c $CLIENT_CPU $CLIENT_CMD
    options:
      min-rounds: $min_rounds
EOF

  codspeed run --config "$WORKSPACE/codspeed.yml" --working-directory /tmp -m walltime
}

# ---------------------------------------------------------------------------
# Setup build artifacts
# ---------------------------------------------------------------------------

chmod +x "$WORKSPACE/artifacts/build-msquic/"* 2>/dev/null || true
chmod +x "$WORKSPACE/artifacts/build-google/"* 2>/dev/null || true
chmod +x "$WORKSPACE/artifacts/build-quiche/"* 2>/dev/null || true
chmod +x "$WORKSPACE/artifacts/build-s2n/"* 2>/dev/null || true
chmod +x "$NEQO/neqo-client" "$NEQO/neqo-server"

# NSS symlink expected by neqo-crypto/build.rs
ln -sfn . "$NEQO/dist"

export LD_LIBRARY_PATH="$NEQO/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NSS_DB_PATH="$NEQO/test-fixture/db"
export NSS_DIR="$NEQO/nss"
export NSS_PREBUILT=1

# ---------------------------------------------------------------------------
# Build walltime benchmarks
# ---------------------------------------------------------------------------

cargo binstall cargo-codspeed --locked --force
cargo codspeed build -p neqo-bench --features bench --locked -m walltime

# ---------------------------------------------------------------------------
# Test data setup
# ---------------------------------------------------------------------------

sudo ip link set dev lo mtu 1500

mkdir -p "$TESTDATA"
openssl req -nodes -new -x509 \
  -keyout "$TESTDATA/key" \
  -out "$TESTDATA/cert" \
  -subj "/CN=localhost" \
  2>/dev/null
truncate -s "$TRANSFER_SIZE" "$TESTDATA/$TRANSFER_SIZE"

# ---------------------------------------------------------------------------
# CPU tuning
# ---------------------------------------------------------------------------

lscpu || true
cat /sys/devices/system/cpu/online || true

for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  tune_sysfs "$gov" "performance" "CPU governor ($gov)"
done
tune_sysfs /sys/devices/system/cpu/smt/control "off" "SMT" "^(off|forceoff|notsupported|notimplemented)$"
for boost in /sys/devices/system/cpu/cpufreq/policy*/boost; do
  tune_sysfs "$boost" "0" "Boost ($boost)"
done

select_cpus

# ---------------------------------------------------------------------------
# Criterion (walltime) benchmarks
# ---------------------------------------------------------------------------

# Pre-generate taskset env vars used by the Criterion bench run (mirrors
# the "Set perfcompare environment" step in the workflow).
gen_commands quiche quiche
QUICHE_QUICHE_SERVER_CMD="taskset -c $SERVER_CPU $SERVER_CMD"
QUICHE_QUICHE_CLIENT_CMD="taskset -c $CLIENT_CPU $CLIENT_CMD"

gen_commands google neqo true true
GOOGLE_NEQO_SERVER_CMD="taskset -c $SERVER_CPU $SERVER_CMD"
GOOGLE_NEQO_CLIENT_CMD="taskset -c $CLIENT_CPU $CLIENT_CMD"

gen_commands quiche neqo true true
QUICHE_NEQO_SERVER_CMD="taskset -c $SERVER_CPU $SERVER_CMD"
QUICHE_NEQO_CLIENT_CMD="taskset -c $CLIENT_CPU $CLIENT_CMD"

export QUICHE_QUICHE_SERVER_CMD QUICHE_QUICHE_CLIENT_CMD
export GOOGLE_NEQO_SERVER_CMD GOOGLE_NEQO_CLIENT_CMD
export QUICHE_NEQO_SERVER_CMD QUICHE_NEQO_CLIENT_CMD

# codspeed run -m walltime -- cargo codspeed run -p neqo-bench
echo SKIPPED

# ---------------------------------------------------------------------------
# quiche vs quiche
# ---------------------------------------------------------------------------

gen_commands quiche quiche
start_server "quiche-quiche"
run_bench "quiche-quiche" 10
stop_server

# ---------------------------------------------------------------------------
# google vs neqo
# ---------------------------------------------------------------------------

gen_commands google neqo true true
start_server "google-neqo"
run_bench "google-neqo" 10
stop_server

# ---------------------------------------------------------------------------
# quiche vs neqo
# ---------------------------------------------------------------------------

gen_commands quiche neqo true true
start_server "quiche-neqo"
run_bench "quiche-neqo" 10
stop_server

echo "Done."

#!/usr/bin/env bash
# Local benchmark script replicating the CodSpeed CI workflow.
# Usage: ./bench-local.sh [--skip-build] [--skip-tuning]
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TRANSFER_SIZE=33554432  # 32 MiB
HOST="127.0.0.1"
PORT="4433"
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
NEQO_PATH="$WORKSPACE/artifacts/build-neqo"
QUICHE_PATH="$WORKSPACE/artifacts/build-quiche"
TESTDATA_PATH="$WORKSPACE/testdata"
MTU=1500
WARMUP_TIME="10s"
MIN_ROUNDS=150

SKIP_BUILD=false
SKIP_TUNING=false
for arg in "$@"; do
  case "$arg" in
    --skip-build)  SKIP_BUILD=true ;;
    --skip-tuning) SKIP_TUNING=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  info "Cleaning up..."
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Rust toolchain & tools
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" == false ]]; then
  info "Installing Rust toolchain (stable)"
  rustup toolchain install stable
  rustup default stable

  info "Installing cargo-codspeed"
  cargo install cargo-binstall --locked 2>/dev/null || true
  cargo binstall cargo-codspeed --locked --force --no-confirm

  info "Installing exec-harness"
  cargo install --locked \
    --git https://github.com/CodSpeedHQ/codspeed \
    --branch "cod-2233-investigate-neqo-variance" \
    exec-harness --force

  cargo install --locked \
    --git https://github.com/CodSpeedHQ/codspeed \
    --branch "cod-2233-investigate-neqo-variance" \
    codspeed-runner --force
fi

# ---------------------------------------------------------------------------
# 2. Build artifacts setup
# ---------------------------------------------------------------------------
info "Setting up build artifacts"
chmod +x "$QUICHE_PATH"/* 2>/dev/null || true
chmod +x "$NEQO_PATH"/neqo-client "$NEQO_PATH"/neqo-server 2>/dev/null || true

# neqo-crypto/build.rs expects $NSS_DIR/../dist/{Release,public,private}.
ln -sfn . "$NEQO_PATH/dist"

export LD_LIBRARY_PATH="${NEQO_PATH}/lib:${LD_LIBRARY_PATH:-}"
export NSS_DB_PATH="$NEQO_PATH/test-fixture/db"
export NSS_DIR="$NEQO_PATH/nss"
export NSS_PREBUILT=1

# ---------------------------------------------------------------------------
# 3. Test data (certs + test files)
# ---------------------------------------------------------------------------
info "Setting up test data in $TESTDATA_PATH"
mkdir -p "$TESTDATA_PATH"

if [[ ! -f "$TESTDATA_PATH/cert" ]]; then
  openssl req -nodes -new -x509 \
    -keyout "$TESTDATA_PATH/key" \
    -out "$TESTDATA_PATH/cert" \
    -subj "/CN=localhost" \
    2>/dev/null
fi

truncate -s "$TRANSFER_SIZE" "$TESTDATA_PATH/$TRANSFER_SIZE"

# ---------------------------------------------------------------------------
# 4. Loopback MTU
# ---------------------------------------------------------------------------
info "Setting loopback MTU to $MTU"
sudo ip link set dev lo mtu "$MTU"

# ---------------------------------------------------------------------------
# 5. CPU tuning
# ---------------------------------------------------------------------------
tune_sysfs() {
  local file="$1" desired="$2" desc="$3" skip="${4:-}"
  [[ -f "$file" ]] || return 0
  local current
  current=$(cat "$file" 2>/dev/null) || return 0
  if [[ -n "$skip" ]]; then
    if [[ "$current" =~ $skip ]]; then
      echo "  $desc: already ok ($current)"
      return 0
    fi
  elif [[ "$current" == "$desired" ]]; then
    echo "  $desc: already set to $desired"
    return 0
  fi
  if ! echo "$desired" | sudo tee "$file" > /dev/null 2>&1; then
    warn "$desc: failed to set $desired (current: $current)"
  else
    echo "  $desc: set to $desired"
  fi
}

if [[ "$SKIP_TUNING" == false ]]; then
  info "Applying CPU tuning"

  # Set governor to performance
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    tune_sysfs "$gov" "performance" "CPU governor ($(basename "$(dirname "$(dirname "$gov")")"))"
  done

  # Disable SMT
  tune_sysfs /sys/devices/system/cpu/smt/control "off" "SMT" "^(off|forceoff|notsupported|notimplemented)$"

  # Disable boost/turbo
  for boost in /sys/devices/system/cpu/cpufreq/policy*/boost; do
    tune_sysfs "$boost" "0" "Boost ($(basename "$(dirname "$boost")"))"
  done
fi

# ---------------------------------------------------------------------------
# 6. Select CPUs for pinning
# ---------------------------------------------------------------------------
info "Selecting CPUs for pinning"
declare -A core_to_cpu=()
for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
  cpu=$(basename "$cpu_path")
  cpu_num=${cpu#cpu}
  core_id_file="$cpu_path/topology/core_id"
  if [[ -f "$core_id_file" ]]; then
    core_id=$(cat "$core_id_file")
    if [[ -z "${core_to_cpu[$core_id]:-}" ]]; then
      core_to_cpu[$core_id]=$cpu_num
    fi
  fi
done

mapfile -t physical_cpus < <(printf '%s\n' "${core_to_cpu[@]}")
mapfile -t sorted < <(printf '%s\n' "${physical_cpus[@]}" | sort -rn)

if [[ ${#sorted[@]} -ge 2 ]]; then
  SERVER_CPU=${sorted[0]}
  CLIENT_CPU=${sorted[1]}
elif [[ ${#sorted[@]} -eq 1 ]]; then
  SERVER_CPU=${sorted[0]}
  CLIENT_CPU=${sorted[0]}
else
  SERVER_CPU=0
  CLIENT_CPU=1
fi
info "Server CPU: $SERVER_CPU, Client CPU: $CLIENT_CPU"

# ---------------------------------------------------------------------------
# 7. Generate benchmark commands (quiche client, neqo server)
# ---------------------------------------------------------------------------
BENCH_NAME="quiche-neqo"
SERVER_CMD="$NEQO_PATH/neqo-server --cc cubic -Q 1 $HOST:$PORT"
CLIENT_CMD="$QUICHE_PATH/quiche-client --no-verify https://$HOST:$PORT/$TRANSFER_SIZE"

info "Bench: $BENCH_NAME"
info "Server: $SERVER_CMD"
info "Client: $CLIENT_CMD"

# ---------------------------------------------------------------------------
# 8. Start server
# ---------------------------------------------------------------------------
info "Killing any previously running server on port $PORT"
sudo kill "$(sudo lsof -t -i UDP:"$PORT")" 2>/dev/null || true
sleep 1

info "Starting server"
# shellcheck disable=SC2086
sudo LD_LIBRARY_PATH="$LD_LIBRARY_PATH" nice -n -20 taskset -c "$SERVER_CPU" $SERVER_CMD &
SERVER_PID=$!
sleep 3

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  die "Server exited prematurely"
fi
if ! ss -ulnp | grep -q ":$PORT "; then
  kill "$SERVER_PID" 2>/dev/null || true
  die "Server is not listening on UDP port $PORT"
fi
info "Server running (PID $SERVER_PID)"

# ---------------------------------------------------------------------------
# 9. Create benchmark config & run
# ---------------------------------------------------------------------------
CONFIG_FILE="$WORKSPACE/codspeed.yml"
cat > "$CONFIG_FILE" <<EOF
benchmarks:
  - name: "$BENCH_NAME"
    exec: taskset -c $CLIENT_CPU $CLIENT_CMD
    options:
      warmup-time: $WARMUP_TIME
      min-rounds: $MIN_ROUNDS
EOF

info "Benchmark config written to $CONFIG_FILE"
info "Running benchmark..."

CODSPEED_PERF_ENABLED=false codspeed run --config "$CONFIG_FILE" -m walltime

info "Done."
